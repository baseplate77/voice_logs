import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/result.dart';

void main() {
  group('Result', () {
    test('Ok construction and accessors', () {
      const Result<int, String> r = Ok<int, String>(42);
      expect(r.isOk, isTrue);
      expect(r.isErr, isFalse);
      expect(r.okOrNull, 42);
      expect(r.errOrNull, isNull);
    });

    test('Err construction and accessors', () {
      const Result<int, String> r = Err<int, String>('boom');
      expect(r.isErr, isTrue);
      expect(r.isOk, isFalse);
      expect(r.okOrNull, isNull);
      expect(r.errOrNull, 'boom');
    });

    test('map transforms Ok, leaves Err untouched', () {
      const Result<int, String> ok = Ok<int, String>(2);
      const Result<int, String> err = Err<int, String>('nope');

      expect(ok.map((v) => v * 10).okOrNull, 20);
      expect(err.map((v) => v * 10).errOrNull, 'nope');
    });

    test('mapErr transforms Err, leaves Ok untouched', () {
      const Result<int, String> ok = Ok<int, String>(5);
      const Result<int, String> err = Err<int, String>('e');

      expect(ok.mapErr((e) => e.length).okOrNull, 5);
      expect(err.mapErr((e) => e.length).errOrNull, 1);
    });

    test('flatMap chains fallible operations', () {
      Result<int, String> parse(String s) {
        final n = int.tryParse(s);
        return n == null
            ? const Err<int, String>('not a number')
            : Ok<int, String>(n);
      }

      const Result<String, String> start = Ok<String, String>('7');
      final chained = start.flatMap(parse).map((v) => v + 1);
      expect(chained.okOrNull, 8);

      const Result<String, String> bad = Ok<String, String>('abc');
      final failed = bad.flatMap(parse);
      expect(failed.errOrNull, 'not a number');
    });

    test('fold collapses to a single value', () {
      const Result<int, String> ok = Ok<int, String>(3);
      const Result<int, String> err = Err<int, String>('x');

      expect(ok.fold((v) => 'ok:$v', (e) => 'err:$e'), 'ok:3');
      expect(err.fold((v) => 'ok:$v', (e) => 'err:$e'), 'err:x');
    });

    test('equality and hashCode by payload', () {
      const a = Ok<int, String>(1);
      const b = Ok<int, String>(1);
      const c = Ok<int, String>(2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));

      const e1 = Err<int, String>('x');
      const e2 = Err<int, String>('x');
      expect(e1, e2);
      expect(a, isNot(e1));
    });
  });
}
