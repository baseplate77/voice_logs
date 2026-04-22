import 'dart:typed_data';

import '../../core/app_error.dart';
import '../../core/result.dart';

/// Abstracts the ASR engine so the UI and tests don't depend on
/// `sherpa_onnx` directly.
abstract class SpeechRecognizer {
  /// Load the underlying model. Must be called once before [transcribe].
  /// Safe to call multiple times; subsequent calls are no-ops.
  Future<Result<void, AsrError>> load();

  /// Transcribe the given wav bytes (16 kHz mono PCM16 with RIFF header).
  /// Returns the recognized text or an error.
  Future<Result<String, AsrError>> transcribeWav(Uint8List wavBytes);

  /// Release any native resources held by the recognizer.
  Future<void> dispose();
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
