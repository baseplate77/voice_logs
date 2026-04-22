import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/offset_recovery.dart';

void main() {
  test('recovers offsets from forward-scan matches', () {
    final out = recoverOffsets(
      cleanedText: 'I met Shivani at Cafe Coffee Day yesterday.',
      mentions: const [
        (text: 'Shivani', type: 'PERSON'),
        (text: 'Cafe Coffee Day', type: 'PLACE'),
      ],
    );
    expect(out, hasLength(2));
    expect(out[0].charStart, 6);
    expect(out[0].charEnd, 13);
    expect(out[1].text, 'Cafe Coffee Day');
    expect(out[1].charStart, 17);
  });

  test('repeated mentions map to distinct occurrences', () {
    final out = recoverOffsets(
      cleanedText: 'Shivani called Shivani.',
      mentions: const [
        (text: 'Shivani', type: 'PERSON'),
        (text: 'Shivani', type: 'PERSON'),
      ],
    );
    expect(out, hasLength(2));
    expect(out[0].charStart, 0);
    expect(out[1].charStart, 15);
  });

  test('missing surfaces are skipped silently', () {
    final out = recoverOffsets(
      cleanedText: 'Just a sentence.',
      mentions: const [(text: 'nope', type: 'PERSON')],
    );
    expect(out, isEmpty);
  });
}
