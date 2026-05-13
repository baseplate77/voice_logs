import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../../core/logger.dart';
import '../../core/result.dart';
import 'speech_recognizer.dart';
import 'wav_io.dart';

/// Paths to the four Parakeet model artifacts on disk. Callers resolve
/// these from asset bundles at app start — see `lib/core/model_paths.dart`.
class ParakeetModelPaths {
  const ParakeetModelPaths({
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });

  /// Path to `encoder.int8.onnx`.
  final String encoder;

  /// Path to `decoder.int8.onnx`.
  final String decoder;

  /// Path to `joiner.int8.onnx`.
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

/// `sherpa_onnx`-backed offline recognizer for the NEMO Parakeet-TDT-0.6b
/// bundle. Streaming (live partial captions) is planned for Phase 1.1 and
/// will swap to a different model + `OnlineRecognizer`; the abstract
/// [SpeechRecognizer] interface insulates callers from that upgrade.
class ParakeetRunner implements SpeechRecognizer {
  ParakeetRunner({required this.paths});

  /// Where the four model files live on disk.
  final ParakeetModelPaths paths;

  final _log = Logger('parakeet');
  sherpa.OfflineRecognizer? _recognizer;
  bool _bindingsInitialized = false;

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
      final config = sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          transducer: sherpa.OfflineTransducerModelConfig(
            encoder: paths.encoder,
            decoder: paths.decoder,
            joiner: paths.joiner,
          ),
          tokens: paths.tokens,
          // NEMO Parakeet ships as a transducer with NEMO-style modeling
          // — sherpa-onnx recognizes it via this model type string.
          modelType: 'nemo_transducer',
          // Benchmarked in bench_results/stt_bench_2026-05-03.md:
          // CPU/4 produced identical transcripts to CPU/2 and improved p50
          // from 9070ms → 6833ms on a 60s Pixel 6a fixture.
          numThreads: 4,
        ),
      );
      _recognizer = sherpa.OfflineRecognizer(config);
      _log.i('Parakeet loaded from ${paths.encoder}');
      return const Ok(null);
    } on Object catch (e, s) {
      return Err(
        AsrLoadFailed(
          message: 'Failed to load Parakeet: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<String, AsrError>> transcribeFile(String wavPath) async {
    final recognizer = _recognizer;
    if (recognizer == null) {
      return const Err(
        AsrRuntimeError(message: 'ParakeetRunner.load() not called.'),
      );
    }
    final wav = File(wavPath);
    if (!wav.existsSync()) {
      return Err(
        AsrRuntimeError(message: 'WAV file not found at path: $wavPath'),
      );
    }
    try {
      final info = await readPcm16WavInfo(wavPath);
      final segments = <String>[];
      await for (final samples in readPcm16WavFloatChunks(
        wavPath,
        samplesPerChunk: _samplesPerTranscriptionChunk,
      )) {
        final stream = recognizer.createStream();
        try {
          stream.acceptWaveform(samples: samples, sampleRate: info.sampleRate);
          recognizer.decode(stream);
          final text = recognizer.getResult(stream).text.trim();
          if (text.isNotEmpty) segments.add(text);
        } finally {
          stream.free();
        }
      }
      return Ok(segments.join(' ').trim());
    } on Object catch (e, s) {
      return Err(
        AsrRuntimeError(
          message: 'Transcription failed: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  static const _samplesPerTranscriptionChunk = 16000 * 30;

  @override
  Future<void> dispose() async {
    _recognizer?.free();
    _recognizer = null;
  }
}
