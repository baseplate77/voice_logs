import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/llm/llm_runner.dart';

void main() {
  group('FakeLlmRunner', () {
    test('generateSync before load errs', () async {
      final runner = FakeLlmRunner(responses: const <String>['hi']);
      final r = await runner.generateSync('anything');
      expect(r.isErr, isTrue);
    });

    test('returns scripted responses and cycles', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['one', 'two', 'three'],
      );
      await runner.load();
      final a = await runner.generateSync('a');
      final b = await runner.generateSync('b');
      final c = await runner.generateSync('c');
      final d = await runner.generateSync('d');
      expect(a.okOrNull, 'one');
      expect(b.okOrNull, 'two');
      expect(c.okOrNull, 'three');
      expect(d.okOrNull, 'one'); // cycled
      expect(runner.callCount, 4);
    });

    test('empty responses list yields empty string', () async {
      final runner = FakeLlmRunner();
      await runner.load();
      final r = await runner.generateSync('anything');
      expect(r.okOrNull, '');
    });

    test('generate streams response in chunks', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['abcdefghijklmnop'],
        streamChunkSize: 4,
      );
      await runner.load();
      final chunks = await runner.generate('p').toList();
      expect(chunks, <String>['abcd', 'efgh', 'ijkl', 'mnop']);
    });

    test('errorAfter turns later calls into Err', () async {
      final runner = FakeLlmRunner(
        responses: const <String>['ok'],
        errorAfter: 1,
      );
      await runner.load();
      final first = await runner.generateSync('a');
      final second = await runner.generateSync('b');
      expect(first.isOk, isTrue);
      expect(second.isErr, isTrue);
    });

    test('dispose blocks further use', () async {
      final runner = FakeLlmRunner(responses: const <String>['hi']);
      await runner.load();
      await runner.dispose();
      final r = await runner.generateSync('anything');
      expect(r.isErr, isTrue);
    });

    test('load after dispose is rejected', () async {
      final runner = FakeLlmRunner();
      await runner.dispose();
      final r = await runner.load();
      expect(r.isErr, isTrue);
    });

    test('generate after dispose throws StateError', () async {
      final runner = FakeLlmRunner(responses: const <String>['hi']);
      await runner.load();
      await runner.dispose();
      expect(
        () async => runner.generate('p').toList(),
        throwsStateError,
      );
    });
  });
}
