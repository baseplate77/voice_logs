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

  /// Release any native resources held by the recognizer.
  Future<void> dispose();
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
