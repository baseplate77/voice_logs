import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/llm_chunker.dart';
import 'package:voxsynth/features/refine/offset_recovery.dart';

void main() {
  group('splitForLlmRefine', () {
    test('returns one chunk for short text', () {
      final chunks = splitForLlmRefine(
        'one two three',
        targetWords: 5,
        overlapWords: 1,
      );
      expect(chunks, hasLength(1));
      expect(chunks.single.text, 'one two three');
    });

    test('splits long text with overlap', () {
      final text = List.generate(12, (i) => 'w$i').join(' ');
      final chunks = splitForLlmRefine(text, targetWords: 5, overlapWords: 2);

      expect(chunks.map((c) => c.text).toList(), [
        'w0 w1 w2 w3 w4',
        'w3 w4 w5 w6 w7',
        'w6 w7 w8 w9 w10',
        'w9 w10 w11',
      ]);
    });
  });

  group('stitchRefinedChunks', () {
    test('removes overlapping chunk prefix and shifts mention offsets', () {
      final stitched = stitchRefinedChunks(
        [
          const RefinedTextChunk(
            index: 0,
            cleanedText: 'I met Shivani at Cafe Coffee Day.',
            mentions: [
              LocatedMention(
                text: 'Shivani',
                type: 'PERSON',
                charStart: 6,
                charEnd: 13,
              ),
            ],
          ),
          const RefinedTextChunk(
            index: 1,
            cleanedText: 'at Cafe Coffee Day. We discussed Project Atlas.',
            mentions: [
              LocatedMention(
                text: 'Cafe Coffee Day',
                type: 'PLACE',
                charStart: 3,
                charEnd: 18,
              ),
              LocatedMention(
                text: 'Project Atlas',
                type: 'PROJECT',
                charStart: 33,
                charEnd: 46,
              ),
            ],
          ),
        ],
        maxOverlapWords: 4,
        minOverlapWordsToDrop: 4,
      );

      expect(
        stitched.cleanedText,
        'I met Shivani at Cafe Coffee Day. We discussed Project Atlas.',
      );
      expect(stitched.mentions.map((m) => m.text).toList(), [
        'Shivani',
        'Project Atlas',
      ]);
      expect(
        stitched.mentions.last.charStart,
        stitched.cleanedText.indexOf('Project Atlas'),
      );
    });
  });
}
