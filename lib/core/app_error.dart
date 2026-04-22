/// Base class for every error surfaced across a layer boundary.
///
/// Feature-specific errors extend this (e.g. `StorageError`, `AsrError`,
/// `LlmError`). Errors always carry a human-readable [message]; [cause] and
/// [stack] are optional, for chaining a source exception when one exists.
sealed class AppError {
  const AppError({required this.message, this.cause, this.stack});

  /// Human-readable error description. Safe to show to the user.
  final String message;

  /// Original exception, if this error wraps one.
  final Object? cause;

  /// Stack trace at the point of failure, if available.
  final StackTrace? stack;

  @override
  String toString() =>
      '$runtimeType(message: $message${cause != null ? ', cause: $cause' : ''})';
}

/// Fallback error type for unexpected failures that no typed error covers.
final class UnknownError extends AppError {
  const UnknownError({required super.message, super.cause, super.stack});
}
