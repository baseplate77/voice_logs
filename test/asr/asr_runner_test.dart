import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/asr/asr_runner.dart';
import 'package:voxsynth/asr/models/transcript.dart';

void main() {
  group('FakeAsrRunner', () {
    test('transcribe before load errs', () async {
      final runner = FakeAsrRunner();
      final r = await runner.transcribe(Uint8List(0));
      expect(r.isErr, isTrue);
    });

    test('empty script returns Transcript.empty', () async {
      final runner = FakeAsrRunner();
      await runner.load();
      final r = await runner.transcribe(Uint8List(0));
      expect(r.okOrNull, Transcript.empty);
    });

    test('returns scripted transcripts in order and cycles', () async {
      const t1 = Transcript(
        text: 'hello',
        words: <Word>[Word(text: 'hello', startMs: 0, endMs: 400, confidence: 0.9)],
        detectedLanguage: 'en',
      );
      const t2 = Transcript(
        text: 'world',
        words: <Word>[Word(text: 'world', startMs: 0, endMs: 400, confidence: 0.9)],
        detectedLanguage: 'en',
      );
      final runner = FakeAsrRunner(transcripts: const <Transcript>[t1, t2]);
      await runner.load();

      final a = await runner.transcribe(Uint8List(0));
      final b = await runner.transcribe(Uint8List(0));
      final c = await runner.transcribe(Uint8List(0));

      expect(a.okOrNull, t1);
      expect(b.okOrNull, t2);
      expect(c.okOrNull, t1); // cycled
      expect(runner.transcribeCallCount, 3);
    });

    test('dispose blocks further calls', () async {
      final runner = FakeAsrRunner();
      await runner.load();
      await runner.dispose();
      final r = await runner.transcribe(Uint8List(0));
      expect(r.isErr, isTrue);
    });

    test('load after dispose is rejected', () async {
      final runner = FakeAsrRunner();
      await runner.dispose();
      final r = await runner.load();
      expect(r.isErr, isTrue);
    });
  });
}
