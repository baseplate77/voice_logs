import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/errors.dart';

void main() {
  group('AppError', () {
    test('PermissionDeniedError carries the permission name', () {
      const err = PermissionDeniedError('microphone');
      expect(err.permission, 'microphone');
      expect(err.message, contains('microphone'));
      expect(err.cause, isNull);
    });

    test('ModelLoadError includes path and reason', () {
      const err = ModelLoadError(
        'assets/models/x.bin',
        reason: 'file not found',
      );
      expect(err.modelPath, 'assets/models/x.bin');
      expect(err.message, contains('assets/models/x.bin'));
      expect(err.message, contains('file not found'));
    });

    test('StorageError preserves cause', () {
      final cause = Exception('disk full');
      final err = StorageError('write failed', cause: cause);
      expect(err.cause, cause);
      expect(err.toString(), contains('disk full'));
    });

    test('IsolateError is an AppError subtype', () {
      const err = IsolateError('isolate died');
      expect(err, isA<AppError>());
    });

    test('UnknownError serves as catch-all', () {
      const err = UnknownError('???');
      expect(err, isA<AppError>());
      expect(err.message, '???');
    });
  });
}
