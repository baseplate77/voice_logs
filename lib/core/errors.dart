/// Domain error hierarchy returned inside [Result].
///
/// Every layer boundary returns `Result<T, AppError>`. Use the most specific
/// subtype possible. Preserve the originating exception in [cause] for logs.
library;

/// Base class for all recoverable failures in VoxSynth.
sealed class AppError {
  const AppError(this.message, {this.cause, this.stackTrace});

  /// Human-readable, user-safe message. Displayed in UI.
  final String message;

  /// The underlying exception, if any. Logged, never shown to users.
  final Object? cause;

  /// Stack trace from the originating `catch` block.
  final StackTrace? stackTrace;

  @override
  String toString() =>
      '$runtimeType: $message${cause == null ? '' : ' (cause: $cause)'}';
}

/// The user or OS denied a required permission.
final class PermissionDeniedError extends AppError {
  const PermissionDeniedError(
    this.permission, {
    super.cause,
    super.stackTrace,
  }) : super('Permission denied: $permission');

  final String permission;
}

/// A model file failed to load (missing, corrupt, wrong format, OOM).
final class ModelLoadError extends AppError {
  const ModelLoadError(
    this.modelPath, {
    required String reason,
    super.cause,
    super.stackTrace,
  }) : super('Failed to load model at $modelPath: $reason');

  final String modelPath;
}

/// A storage backend (SQLite, ObjectBox, filesystem) reported an error.
final class StorageError extends AppError {
  const StorageError(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}

/// A background isolate crashed or failed to start.
final class IsolateError extends AppError {
  const IsolateError(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}

/// Generic catch-all. Prefer a specific subtype when possible.
final class UnknownError extends AppError {
  const UnknownError(
    super.message, {
    super.cause,
    super.stackTrace,
  });
}
