import 'dart:convert';
import 'dart:typed_data';

import '../../core/app_error.dart';
import '../../core/result.dart';

/// Abstracts the ASR engine so the UI and tests don't depend on
/// `sherpa_onnx` directly.
abstract class SpeechRecognizer {
  /// Load the underlying model. Must be called once before [transcribeFile].
  /// Safe to call multiple times; subsequent calls are no-ops.
  Future<Result<void, AsrError>> load();

  /// Transcribe the given wav file path (16 kHz mono PCM16 with RIFF header).
  /// Returns the recognized text or an error.
  Future<Result<String, AsrError>> transcribeFile(String wavPath);

  /// Transcribe with per-segment text and per-word timings when supported.
  /// Implementations that lack timing must return a result with one segment
  /// containing the full transcript and an empty `words` list.
  Future<Result<TranscriptionResult, AsrError>> transcribeFileDetailed(
    String wavPath,
  );

  /// Release any native resources held by the recognizer.
  Future<void> dispose();
}

/// Per-segment transcription result with optional word timings.
class TranscriptSegmentResult {
  const TranscriptSegmentResult({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.words,
  });

  /// Recognized text for this segment.
  final String text;

  /// Segment start time in milliseconds, measured from the start of the WAV.
  final int startMs;

  /// Segment end time in milliseconds.
  final int endMs;

  /// Per-word timings in this segment. Empty when the recognizer doesn't
  /// expose word-level timing.
  final List<WordTiming> words;
}

/// Aggregated transcription output for a WAV file.
class TranscriptionResult {
  const TranscriptionResult({required this.segments});

  /// One result per chunk fed to the recognizer.
  final List<TranscriptSegmentResult> segments;

  /// Full transcript — segment texts joined by single spaces.
  String get text =>
      segments.map((s) => s.text).where((t) => t.isNotEmpty).join(' ').trim();

  /// Convenience constructor for recognizers without timing support.
  factory TranscriptionResult.textOnly(String text, {int? durationMs}) {
    return TranscriptionResult(
      segments: [
        TranscriptSegmentResult(
          text: text,
          startMs: 0,
          endMs: durationMs ?? 0,
          words: const [],
        ),
      ],
    );
  }
}

/// Word with absolute start/end times in the source recording.
class WordTiming {
  const WordTiming({
    required this.word,
    required this.startMs,
    required this.endMs,
  });

  /// The decoded word, with any tokenizer boundary marker stripped.
  final String word;

  /// Word start time in milliseconds since the beginning of the WAV.
  final int startMs;

  /// Word end time in milliseconds.
  final int endMs;

  /// Encode as a compact JSON object.
  Map<String, Object?> toJson() => {
    'word': word,
    'startMs': startMs,
    'endMs': endMs,
  };

  /// Parse from the JSON shape emitted by [toJson].
  factory WordTiming.fromJson(Map<String, Object?> json) => WordTiming(
    word: json['word'] as String,
    startMs: json['startMs'] as int,
    endMs: json['endMs'] as int,
  );
}

/// Encode a list of word timings as a JSON string for storage in
/// `transcript_segments.word_timings_json`. Returns `null` when [words] is
/// empty to avoid writing useless empty arrays.
String? encodeWordTimings(List<WordTiming> words) {
  if (words.isEmpty) return null;
  return jsonEncode(words.map((w) => w.toJson()).toList());
}

/// Decode the JSON shape written by [encodeWordTimings]. Returns an empty
/// list when [encoded] is null or empty.
List<WordTiming> decodeWordTimings(String? encoded) {
  if (encoded == null || encoded.isEmpty) return const [];
  final raw = jsonDecode(encoded) as List<dynamic>;
  return raw
      .map((e) => WordTiming.fromJson((e as Map).cast<String, Object?>()))
      .toList(growable: false);
}

/// Optional extension for recognizers that can consume microphone PCM chunks.
///
/// The recording controller detects this interface and uses it for live
/// captions plus a low-latency final raw transcript. Non-streaming engines
/// still work through [SpeechRecognizer.transcribeFile].
abstract class StreamingSpeechRecognizer implements SpeechRecognizer {
  /// Start a fresh streaming session.
  Future<Result<void, AsrError>> beginStream();

  /// Feed one chunk of little-endian signed PCM16 mono audio.
  Future<Result<String, AsrError>> acceptPcm16(
    Uint8List chunk, {
    int sampleRate = 16000,
  });

  /// Finish the current session and return the final hypothesis.
  Future<Result<String, AsrError>> finishStream();
}

/// Errors surfaced by the ASR layer.
sealed class AsrError extends AppError {
  const AsrError({required super.message, super.cause, super.stack});
}

/// Model files missing on disk.
final class AsrModelMissing extends AsrError {
  const AsrModelMissing(String path)
    : super(message: 'ASR model file not found: $path');
}

/// The native recognizer failed to initialize.
final class AsrLoadFailed extends AsrError {
  const AsrLoadFailed({required super.message, super.cause, super.stack});
}

/// Transcription threw at runtime.
final class AsrRuntimeError extends AsrError {
  const AsrRuntimeError({required super.message, super.cause, super.stack});
}
