import 'package:flutter_test/flutter_test.dart';
import 'package:logger/logger.dart' as pkg;
import 'package:voxsynth/core/logger.dart';

class _CaptureOutput extends pkg.LogOutput {
  final List<pkg.OutputEvent> events = <pkg.OutputEvent>[];

  @override
  void output(pkg.OutputEvent event) => events.add(event);
}

void main() {
  group('AppLogger', () {
    test('emits debug/info/warn/error at matching levels', () {
      final capture = _CaptureOutput();
      final log = AppLogger(output: capture);

      log.debug('d');
      log.info('i');
      log.warn('w');
      log.error('e');

      final levels = capture.events.map((e) => e.level).toList();
      expect(
        levels,
        containsAll(<pkg.Level>[
          pkg.Level.debug,
          pkg.Level.info,
          pkg.Level.warning,
          pkg.Level.error,
        ]),
      );
    });

    test('respects level filter (info suppresses debug)', () {
      final capture = _CaptureOutput();
      final log = AppLogger(level: pkg.Level.info, output: capture);

      log.debug('should-not-appear');
      log.info('should-appear');

      final levels = capture.events.map((e) => e.level).toList();
      expect(levels, isNot(contains(pkg.Level.debug)));
      expect(levels, contains(pkg.Level.info));
    });
  });
}
