/// App-wide logging. Never `print`.
///
/// Exposed via a Riverpod provider per CLAUDE.md ("no singletons, use
/// providers"). Wraps the `logger` package with a VoxSynth-specific default
/// configuration: short timestamps, no emoji, no stack traces at info level.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logger/logger.dart' as pkg;

/// VoxSynth's app logger. Thin facade over `package:logger`.
///
/// Prefer obtaining one via [appLoggerProvider] in app code. Unit tests may
/// construct a [AppLogger] directly with a test [pkg.LogOutput].
class AppLogger {
  AppLogger({pkg.Level? level, pkg.LogOutput? output})
      : _inner = pkg.Logger(
          level: level,
          printer: pkg.PrettyPrinter(
            methodCount: 0,
            lineLength: 100,
            printEmojis: false,
            dateTimeFormat: pkg.DateTimeFormat.onlyTimeAndSinceStart,
          ),
          output: output,
        );

  final pkg.Logger _inner;

  void debug(String message, {Object? error, StackTrace? stackTrace}) =>
      _inner.d(message, error: error, stackTrace: stackTrace);

  void info(String message, {Object? error, StackTrace? stackTrace}) =>
      _inner.i(message, error: error, stackTrace: stackTrace);

  void warn(String message, {Object? error, StackTrace? stackTrace}) =>
      _inner.w(message, error: error, stackTrace: stackTrace);

  void error(String message, {Object? error, StackTrace? stackTrace}) =>
      _inner.e(message, error: error, stackTrace: stackTrace);

  /// Releases underlying resources. Call from provider dispose.
  void close() => _inner.close();
}

/// App-wide logger provider.
///
/// Override in tests:
/// ```dart
/// ProviderScope(overrides: [
///   appLoggerProvider.overrideWithValue(AppLogger(output: TestOutput())),
/// ])
/// ```
final Provider<AppLogger> appLoggerProvider = Provider<AppLogger>((ref) {
  final logger = AppLogger();
  ref.onDispose(logger.close);
  return logger;
});
