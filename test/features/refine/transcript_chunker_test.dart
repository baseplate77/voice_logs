import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/transcript_chunker.dart';

void main() {
  test('splitTranscriptForRefine preserves exact transcript text', () {
    final transcript = List<String>.generate(
      30,
      (i) => 'Sentence $i has a useful project detail and a time at $i PM.',
    ).join(' ');

    final chunks = splitTranscriptForRefine(transcript, maxChars: 180);

    expect(chunks.length, greaterThan(1));
    expect(chunks.map((c) => c.text).join(), transcript);
    for (final chunk in chunks) {
      expect(
        chunk.text,
        transcript.substring(chunk.sourceStart, chunk.sourceEnd),
      );
      expect(chunk.text.length, lessThanOrEqualTo(180));
    }
  });

  test('splitTranscriptForRefine prefers sentence boundaries', () {
    final transcript = '${'alpha ' * 35}. ${'beta ' * 35}. ${'gamma ' * 35}.';

    final chunks = splitTranscriptForRefine(transcript, maxChars: 260);

    expect(chunks.length, greaterThan(1));
    expect(chunks.first.text.trimRight().endsWith('.'), isTrue);
    expect(chunks.map((c) => c.text).join(), transcript);
  });

  test('splitTranscriptForRefine falls back to whitespace for ASR text', () {
    final transcript = List<String>.generate(80, (i) => 'word$i').join(' ');

    final chunks = splitTranscriptForRefine(transcript, maxChars: 150);

    expect(chunks.length, greaterThan(1));
    expect(chunks.map((c) => c.text).join(), transcript);
    for (final chunk in chunks.take(chunks.length - 1)) {
      expect(chunk.text.endsWith(' '), isTrue);
    }
  });
}
