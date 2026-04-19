/// A sealed sum type for operations that can fail.
///
/// Per CLAUDE.md: "All async operations return `Result<T, AppError>` — never
/// throw across layer boundaries." Use this instead of exceptions for
/// recoverable failures. Programmer errors (assertion failures, null checks,
/// invariant violations) should still throw.
library;

/// Either an [Ok] carrying a value or an [Err] carrying a failure.
sealed class Result<T, E> {
  const Result();

  /// True when this is an [Ok].
  bool get isOk => this is Ok<T, E>;

  /// True when this is an [Err].
  bool get isErr => this is Err<T, E>;

  /// Returns the [Ok] value, or `null` if this is an [Err].
  T? get okOrNull => switch (this) {
    Ok<T, E>(:final value) => value,
    Err<T, E>() => null,
  };

  /// Returns the [Err] value, or `null` if this is an [Ok].
  E? get errOrNull => switch (this) {
    Ok<T, E>() => null,
    Err<T, E>(:final error) => error,
  };

  /// Transforms the [Ok] value, leaves [Err] unchanged.
  Result<U, E> map<U>(U Function(T) f) => switch (this) {
    Ok<T, E>(:final value) => Ok<U, E>(f(value)),
    Err<T, E>(:final error) => Err<U, E>(error),
  };

  /// Transforms the [Err] value, leaves [Ok] unchanged.
  Result<T, F> mapErr<F>(F Function(E) f) => switch (this) {
    Ok<T, E>(:final value) => Ok<T, F>(value),
    Err<T, E>(:final error) => Err<T, F>(f(error)),
  };

  /// Monadic bind: chain a fallible operation.
  Result<U, E> flatMap<U>(Result<U, E> Function(T) f) => switch (this) {
    Ok<T, E>(:final value) => f(value),
    Err<T, E>(:final error) => Err<U, E>(error),
  };

  /// Collapse into a single value by handling both branches.
  R fold<R>(R Function(T) onOk, R Function(E) onErr) => switch (this) {
    Ok<T, E>(:final value) => onOk(value),
    Err<T, E>(:final error) => onErr(error),
  };
}

/// The success variant.
final class Ok<T, E> extends Result<T, E> {
  const Ok(this.value);
  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Ok<T, E> && other.value == value);

  @override
  int get hashCode => Object.hash(runtimeType, value);

  @override
  String toString() => 'Ok($value)';
}

/// The failure variant.
final class Err<T, E> extends Result<T, E> {
  const Err(this.error);
  final E error;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is Err<T, E> && other.error == error);

  @override
  int get hashCode => Object.hash(runtimeType, error);

  @override
  String toString() => 'Err($error)';
}
