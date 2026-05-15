import 'dart:io';
import 'dart:isolate';

import 'package:meta/meta.dart';
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

/// Background-isolate Parakeet wrapper used by the app recording flow.
///
/// The underlying sherpa-onnx decode calls are synchronous and can block the
/// UI isolate long enough to freeze loading indicators. This wrapper creates,
/// runs, and disposes [ParakeetRunner] inside a worker isolate for each
/// completed-file transcription, keeping the transcribing UI animated.
class IsolateParakeetRunner implements SpeechRecognizer {
  IsolateParakeetRunner({required this.paths});

  /// Where the four model files live on disk.
  final ParakeetModelPaths paths;

  @override
  Future<Result<void, AsrError>> load() async {
    if (!paths.allExist) return Err(AsrModelMissing(paths.encoder));
    return const Ok(null);
  }

  @override
  Future<Result<String, AsrError>> transcribeFile(String wavPath) async {
    final detailed = await transcribeFileDetailed(wavPath);
    return detailed.map((r) => r.text);
  }

  @override
  Future<Result<TranscriptionResult, AsrError>> transcribeFileDetailed(
    String wavPath,
  ) async {
    final paths = this.paths;
    final payload = await Isolate.run(
      () => _transcribeParakeetPayload(paths: paths, wavPath: wavPath),
    );
    if (payload['ok'] != true) {
      return Err(
        AsrRuntimeError(message: payload['error'] as String? ?? 'ASR failed'),
      );
    }
    return Ok(_decodeTranscriptionPayload(payload));
  }

  @override
  Future<void> dispose() async {}
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
    final detailed = await transcribeFileDetailed(wavPath);
    return detailed.map((r) => r.text);
  }

  @override
  Future<Result<TranscriptionResult, AsrError>> transcribeFileDetailed(
    String wavPath,
  ) async {
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
      final segments = <TranscriptSegmentResult>[];
      var samplesConsumed = 0;
      await for (final samples in readPcm16WavFloatChunks(
        wavPath,
        samplesPerChunk: _samplesPerTranscriptionChunk,
      )) {
        final chunkStartMs = _samplesToMs(samplesConsumed, info.sampleRate);
        final chunkDurationMs = _samplesToMs(samples.length, info.sampleRate);
        samplesConsumed += samples.length;

        final stream = recognizer.createStream();
        try {
          stream.acceptWaveform(samples: samples, sampleRate: info.sampleRate);
          recognizer.decode(stream);
          final result = recognizer.getResult(stream);
          final text = result.text.trim();
          if (text.isEmpty) continue;

          final words = _wordsFromTokens(
            tokens: result.tokens,
            timestampsSeconds: result.timestamps,
            chunkOffsetMs: chunkStartMs,
            chunkEndMs: chunkStartMs + chunkDurationMs,
          );

          segments.add(
            TranscriptSegmentResult(
              text: text,
              startMs: chunkStartMs,
              endMs: chunkStartMs + chunkDurationMs,
              words: words,
            ),
          );
        } finally {
          stream.free();
        }
      }
      return Ok(TranscriptionResult(segments: segments));
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

  static int _samplesToMs(int samples, int sampleRate) =>
      (samples * 1000) ~/ sampleRate;

  @override
  Future<void> dispose() async {
    _recognizer?.free();
    _recognizer = null;
  }
}

/// SentencePiece word-boundary marker emitted by NEMO Parakeet tokenizers.
const String _sentencePieceBoundary = '▁';

/// Tokens that should never start or extend a word.
const Set<String> _ignoredTokens = {'<blk>', '<blank>', '<unk>', '<s>', '</s>'};

/// Group sherpa-onnx token+timestamp output into word-level timings.
///
/// Each token whose string starts with the SentencePiece boundary marker
/// `▁` (U+2581) opens a new word; subsequent non-boundary tokens append to
/// the current word. Word end times are inferred from the next word's
/// start time, or [chunkEndMs] for the final word. Timestamps from sherpa
/// are seconds relative to the chunk start; [chunkOffsetMs] shifts them
/// into absolute WAV time.
List<WordTiming> _wordsFromTokens({
  required List<String> tokens,
  required List<double> timestampsSeconds,
  required int chunkOffsetMs,
  required int chunkEndMs,
}) {
  if (tokens.isEmpty) return const [];
  final pairs = <_TokenWithMs>[];
  final pairCount = tokens.length < timestampsSeconds.length
      ? tokens.length
      : timestampsSeconds.length;
  for (var i = 0; i < pairCount; i++) {
    final token = tokens[i];
    if (_ignoredTokens.contains(token)) continue;
    final tsMs = (timestampsSeconds[i] * 1000).round() + chunkOffsetMs;
    pairs.add(_TokenWithMs(token, tsMs));
  }
  if (pairs.isEmpty) return const [];

  final words = <_WordBuilder>[];
  for (final pair in pairs) {
    final token = pair.token;
    if (token.startsWith(_sentencePieceBoundary) || words.isEmpty) {
      final stripped = token.startsWith(_sentencePieceBoundary)
          ? token.substring(_sentencePieceBoundary.length)
          : token;
      words.add(_WordBuilder(text: stripped, startMs: pair.startMs));
    } else {
      words.last.text += token;
    }
  }

  final result = <WordTiming>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    if (w.text.isEmpty) continue;
    final endMs = i + 1 < words.length ? words[i + 1].startMs : chunkEndMs;
    result.add(
      WordTiming(
        word: w.text,
        startMs: w.startMs,
        endMs: endMs > w.startMs ? endMs : w.startMs,
      ),
    );
  }
  return result;
}

class _TokenWithMs {
  const _TokenWithMs(this.token, this.startMs);
  final String token;
  final int startMs;
}

class _WordBuilder {
  _WordBuilder({required this.text, required this.startMs});
  String text;
  final int startMs;
}

Future<Map<String, Object?>> _transcribeParakeetPayload({
  required ParakeetModelPaths paths,
  required String wavPath,
}) async {
  final runner = ParakeetRunner(paths: paths);
  try {
    final loaded = await runner.load();
    switch (loaded) {
      case Ok():
        break;
      case Err(:final error):
        return {'ok': false, 'error': error.message};
    }
    final result = await runner.transcribeFileDetailed(wavPath);
    switch (result) {
      case Ok(:final value):
        return {
          'ok': true,
          'segments': value.segments
              .map(
                (segment) => {
                  'text': segment.text,
                  'startMs': segment.startMs,
                  'endMs': segment.endMs,
                  'words': segment.words.map((word) => word.toJson()).toList(),
                },
              )
              .toList(),
        };
      case Err(:final error):
        return {'ok': false, 'error': error.message};
    }
  } on Object catch (e) {
    return {'ok': false, 'error': 'Parakeet isolate failed: $e'};
  } finally {
    await runner.dispose();
  }
}

TranscriptionResult _decodeTranscriptionPayload(Map<String, Object?> payload) {
  final rawSegments = (payload['segments'] as List<dynamic>? ?? const []);
  return TranscriptionResult(
    segments: rawSegments
        .map((raw) {
          final map = (raw as Map).cast<String, Object?>();
          final rawWords = (map['words'] as List<dynamic>? ?? const []);
          return TranscriptSegmentResult(
            text: map['text'] as String? ?? '',
            startMs: map['startMs'] as int? ?? 0,
            endMs: map['endMs'] as int? ?? 0,
            words: rawWords
                .map(
                  (rawWord) => WordTiming.fromJson(
                    (rawWord as Map).cast<String, Object?>(),
                  ),
                )
                .toList(growable: false),
          );
        })
        .toList(growable: false),
  );
}

/// Test hook: expose the private token→word reconstruction.
@visibleForTesting
List<WordTiming> reconstructWordsFromTokens({
  required List<String> tokens,
  required List<double> timestampsSeconds,
  required int chunkOffsetMs,
  required int chunkEndMs,
}) => _wordsFromTokens(
  tokens: tokens,
  timestampsSeconds: timestampsSeconds,
  chunkOffsetMs: chunkOffsetMs,
  chunkEndMs: chunkEndMs,
);
