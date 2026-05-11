import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/refine/smollm/bpe_tokenizer.dart';
import 'package:voxsynth/features/refine/smollm/chat_template.dart';

/// Minimal byte-level BPE fixture covering the bits SmolLM2 actually
/// exercises in these tests:
///
/// - GPT-2 byte mapping: space (0x20) becomes 'Ġ' (U+0120) under the
///   standard byte-encoder permutation.
/// - Two added special tokens with reserved ids.
/// - Vocab + merges to encode "hi", " hi", and "hi there".
const _vocab = <String, int>{
  'h': 10,
  'i': 11,
  't': 12,
  'e': 13,
  'r': 14,
  'Ġ': 20,
  'Ġh': 21,
  'Ġhi': 22,
  'Ġt': 23,
  'Ġth': 24,
  'Ġthe': 25,
  'Ġther': 26,
  'Ġthere': 27,
};

const _merges = <String>[
  'Ġ h',
  'Ġh i',
  'Ġ t',
  'Ġt h',
  'Ġth e',
  'Ġthe r',
  'Ġther e',
];

const _addedTokens = [
  {'id': 1, 'content': '<|im_start|>', 'special': true},
  {'id': 2, 'content': '<|im_end|>', 'special': true},
  {'id': 3, 'content': '<|endoftext|>', 'special': true},
];

Future<String> _writeFixture(Directory dir) async {
  final tokenizerJson = {
    'added_tokens': _addedTokens,
    'model': {'type': 'BPE', 'vocab': _vocab, 'merges': _merges},
  };
  final path = p.join(dir.path, 'tokenizer.json');
  await File(path).writeAsString(jsonEncode(tokenizerJson));

  final cfg = {'eos_token': '<|im_end|>', 'bos_token': '<|im_start|>'};
  await File(
    p.join(dir.path, 'tokenizer_config.json'),
  ).writeAsString(jsonEncode(cfg));
  return path;
}

void main() {
  late Directory tmp;
  late BpeTokenizer tokenizer;

  setUpAll(() async {
    tmp = await Directory.systemTemp.createTemp('bpe_test_');
    final tokenizerPath = await _writeFixture(tmp);
    final result = await BpeTokenizer.load(
      tokenizerJsonPath: tokenizerPath,
      tokenizerConfigPath: p.join(tmp.path, 'tokenizer_config.json'),
    );
    tokenizer = switch (result) {
      Ok(:final value) => value,
      Err(:final error) => fail('Tokenizer load failed: ${error.message}'),
    };
  });

  tearDownAll(() async {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('decodes special token ids from added_tokens', () {
    expect(tokenizer.specialTokens['<|im_start|>'], 1);
    expect(tokenizer.specialTokens['<|im_end|>'], 2);
    expect(tokenizer.eosTokenId, 2);
    expect(tokenizer.bosTokenId, 1);
  });

  test('encodes plain ASCII without leading space', () {
    expect(tokenizer.encode('hi'), [10, 11]);
  });

  test('byte-encodes leading space as Ġ and merges greedily', () {
    expect(tokenizer.encode(' hi'), [22]);
  });

  test('handles multi-word input by pre-tokenising whitespace', () {
    expect(tokenizer.encode('hi there'), [10, 11, 27]);
  });

  test('encodeSegments emits special-token ids verbatim', () {
    const prompt = ChatPrompt([
      ChatSpecial('<|im_start|>'),
      ChatText('hi'),
      ChatSpecial('<|im_end|>'),
    ]);
    final result = tokenizer.encodeSegments(prompt.segments);
    final ids = switch (result) {
      Ok(:final value) => value,
      Err(:final error) => fail('Encode failed: ${error.message}'),
    };
    expect(ids, [1, 10, 11, 2]);
  });

  test('encodeSegments returns Err on unknown special token', () {
    const prompt = ChatPrompt([ChatSpecial('<|nope|>')]);
    final result = tokenizer.encodeSegments(prompt.segments);
    expect(result.isOk, isFalse);
  });

  test('decode round-trips byte-encoded text', () {
    final ids = tokenizer.encode(' hi there');
    expect(tokenizer.decode(ids), ' hi there');
  });

  test('decode skips special tokens by default', () {
    expect(tokenizer.decode(const [1, 10, 11, 2]), 'hi');
    expect(
      tokenizer.decode(const [1, 10, 11, 2], skipSpecial: false),
      '<|im_start|>hi<|im_end|>',
    );
  });
}
