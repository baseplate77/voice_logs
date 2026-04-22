import 'package:logger/logger.dart' as pkg;

/// Tagged logger used in place of `print` throughout the app.
///
/// Wraps `package:logger` with a namespace tag so log lines are attributable
/// to a subsystem. `print` is banned by lint; use this instead.
final class Logger {
  /// Create a logger scoped to [tag].
  Logger(this.tag)
    : _impl = pkg.Logger(printer: pkg.PrettyPrinter(methodCount: 0));

  /// Subsystem tag, prefixed to every line.
  final String tag;
  final pkg.Logger _impl;

  /// Debug-level message.
  void d(String message) => _impl.d('[$tag] $message');

  /// Info-level message.
  void i(String message) => _impl.i('[$tag] $message');

  /// Warning with optional cause.
  void w(String message, {Object? error, StackTrace? stack}) =>
      _impl.w('[$tag] $message', error: error, stackTrace: stack);

  /// Error with optional cause.
  void e(String message, {Object? error, StackTrace? stack}) =>
      _impl.e('[$tag] $message', error: error, stackTrace: stack);
}
