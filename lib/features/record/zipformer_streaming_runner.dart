import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/logger.dart';
import '../../core/result.dart';
import 'speech_recognizer.dart';

/// Paths to the small English streaming Zipformer model artifacts.
///
/// This model is used for low-latency live captions and the immediate
/// raw transcript. The heavier Parakeet runner remains available for a
/// future high-quality second pass.
class ZipformerStreamingModelPaths {
  const ZipformerStreamingModelPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  /// Path to `encoder-epoch-99-avg-1.int8.onnx`.
  final String encoder;

  /// Path to `decoder-epoch-99-avg-1.onnx`.
  final String decoder;

  /// Path to `joiner-epoch-99-avg-1.int8.onnx`.
  final String joiner;

  /// Path to `tokens.txt`.
  final String tokens;

  /// True when every file referenced by this struct exists on disk.
  bool get allExist =>
      File(encoder).existsSync() &&
      File(decoder).existsSync() &&
      File(joiner).existsSync() &&
      File(tokens).existsSync();
}

/// Streaming English ASR backed by sherpa-onnx's OnlineRecognizer.
///
/// It accepts PCM16 chunks from the recorder for live hypotheses and can
/// also transcribe a completed wav file through the same online model.
class ZipformerStreamingRunner implements StreamingSpeechRecognizer {
  ZipformerStreamingRunner({required this.paths});

  /// Where the four model files live on disk.
  final ZipformerStreamingModelPaths paths;

  final _log = Logger('zipformer_streaming');
  sherpa.OnlineRecognizer? _recognizer;
  sherpa.OnlineStream? _activeStream;
  bool _bindingsInitialized = false;
  String _lastText = '';

  @override
  Future<Result<void, AsrError>> load() async {
    if (_recognizer != null) return const Ok(null);
    if (!paths.allExist) {
      return Err(AsrModelMissing(paths.encoder));
    }
    try {
      if (!_bindingsInitialized) {
        sherpa.initBindings();
        _bindingsInitialized = true;
      }
      final model = sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: paths.encoder,
          decoder: paths.decoder,
          joiner: paths.joiner,
        ),
        tokens: paths.tokens,
        numThreads: 2,
        // The 2023 English 20M streaming Zipformer package predates
        // Zipformer2 metadata such as `query_head_dims`. Do not set
        // modelType to `zipformer2`; sherpa-onnx's default empty value
        // uses the legacy Zipformer loader and avoids a native crash.
        debug: false,
      );
      _recognizer = sherpa.OnlineRecognizer(
        sherpa.OnlineRecognizerConfig(model: model),
      );
      _log.i('Streaming Zipformer loaded from ${paths.encoder}');
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        AsrLoadFailed(
          message: 'Failed to load streaming Zipformer: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<void, AsrError>> beginStream() async {
    final loaded = await load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }
    try {
      _activeStream?.free();
      _activeStream = _recognizer!.createStream();
      _lastText = '';
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        AsrRuntimeError(
          message: 'Failed to start streaming ASR: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<String, AsrError>> acceptPcm16(
    Uint8List chunk, {
    int sampleRate = 16000,
  }) async {
    final stream = _activeStream;
    final recognizer = _recognizer;
    if (stream == null || recognizer == null) {
      return const Err(AsrRuntimeError(message: 'Streaming ASR not started.'));
    }
    try {
      stream.acceptWaveform(
        samples: pcm16BytesToFloat32(chunk),
        sampleRate: sampleRate,
      );
      _decodeReady(recognizer, stream);
      _lastText = recognizer.getResult(stream).text.trim();
      if (recognizer.isEndpoint(stream)) {
        recognizer.reset(stream);
      }
      return Ok(_lastText);
    } on Object catch (e, s) {
      return Err(
        AsrRuntimeError(
          message: 'Streaming ASR chunk failed: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<String, AsrError>> finishStream() async {
    final stream = _activeStream;
    final recognizer = _recognizer;
    if (stream == null || recognizer == null) {
      return Ok(_lastText);
    }
    try {
      stream.inputFinished();
      _decodeReady(recognizer, stream);
      _lastText = recognizer.getResult(stream).text.trim();
      stream.free();
      _activeStream = null;
      return Ok(_lastText);
    } on Object catch (e, s) {
      return Err(
        AsrRuntimeError(
          message: 'Streaming ASR finish failed: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<String, AsrError>> transcribeFile(String wavPath) async {
    final loaded = await load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return Err(error);
    }
    final recognizer = _recognizer;
    if (recognizer == null) {
      return const Err(
        AsrRuntimeError(message: 'ZipformerStreamingRunner.load() failed.'),
      );
    }
    if (!File(wavPath).existsSync()) {
      return Err(AsrRuntimeError(message: 'WAV file not found: $wavPath'));
    }
    try {
      final wave = sherpa.readWave(wavPath);
      final stream = recognizer.createStream();
      try {
        stream.acceptWaveform(
          samples: wave.samples,
          sampleRate: wave.sampleRate,
        );
        stream.inputFinished();
        _decodeReady(recognizer, stream);
        return Ok(recognizer.getResult(stream).text.trim());
      } finally {
        stream.free();
      }
    } on Object catch (e, s) {
      return Err(
        AsrRuntimeError(
          message: 'Streaming Zipformer transcription failed: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  void _decodeReady(
    sherpa.OnlineRecognizer recognizer,
    sherpa.OnlineStream stream,
  ) {
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
  }

  @override
  Future<void> dispose() async {
    _activeStream?.free();
    _activeStream = null;
    _recognizer?.free();
    _recognizer = null;
  }
}

/// Convert little-endian signed PCM16 bytes to normalized float samples.
@visibleForTesting
Float32List pcm16BytesToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final out = Float32List(sampleCount);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < sampleCount; i++) {
    out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}
