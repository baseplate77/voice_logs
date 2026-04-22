import 'app_error.dart';

/// Discriminated result returned by every async operation that can fail.
///
/// Layer boundaries in VoxSynth return [Result] instead of throwing. Thrown
/// exceptions stay inside a single layer — they cross layer lines as [Err].
///
/// Pattern-match with Dart 3 switch expressions:
///
/// ```dart
/// final res = await repo.load(id);
/// switch (res) {
///   case Ok(:final value): use(value);
///   case Err(:final error): show(error);
/// }
/// ```
sealed class Result<T, E extends AppError> {
  const Result();

  /// True if this is an [Ok] variant.
  bool get isOk => this is Ok<T, E>;

  /// True if this is an [Err] variant.
  bool get isErr => this is Err<T, E>;

  /// Map the success value, preserving the error type.
  Result<R, E> map<R>(R Function(T value) f) => switch (this) {
    Ok<T, E>(:final value) => Ok(f(value)),
    Err<T, E>(:final error) => Err(error),
  };
}

/// Success variant.
final class Ok<T, E extends AppError> extends Result<T, E> {
  /// The successful value.
  final T value;
  const Ok(this.value);
}

/// Failure variant.
final class Err<T, E extends AppError> extends Result<T, E> {
  /// The error describing what went wrong.
  final E error;
  const Err(this.error);
}
