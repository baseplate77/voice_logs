import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/search/tokenizer.dart';

void main() {
  test('encode pads input ids and attention mask to max length', () {
    final tokenizer = BertWordPieceTokenizer.forTesting(
      vocab: const {
        '[PAD]': 0,
        '[UNK]': 100,
        '[CLS]': 101,
        '[SEP]': 102,
        'hello': 7592,
      },
    );

    final tokens = tokenizer.encode('hello', maxLength: 8);

    expect(tokens.inputIds, [101, 7592, 102, 0, 0, 0, 0, 0]);
    expect(tokens.attentionMask, [1, 1, 1, 0, 0, 0, 0, 0]);
  });
}
