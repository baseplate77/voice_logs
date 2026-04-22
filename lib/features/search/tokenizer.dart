import 'dart:convert';
import 'dart:io';

import '../../core/app_error.dart';
import '../../core/result.dart';

/// One tokenized input ready to hand to the e5 ONNX model.
class Tokens {
  const Tokens({required this.inputIds, required this.attentionMask});

  /// Integer token ids.
  final List<int> inputIds;

  /// 1 where a token is present, 0 for padding.
  final List<int> attentionMask;
}

/// Abstract tokenizer — e5-small-v2 ships a BERT WordPiece tokenizer in
/// `tokenizer.json`. Keeping an interface lets tests substitute a
/// canned tokenization without loading a 450 KB vocab.
abstract class Tokenizer {
  Tokens encode(String text, {int maxLength = 512});
}

/// Tokenizer errors.
sealed class TokenizerError extends AppError {
  const TokenizerError({required super.message, super.cause, super.stack});
}

/// tokenizer.json file was unreadable or malformed.
final class TokenizerLoadError extends TokenizerError {
  const TokenizerLoadError({required super.message, super.cause, super.stack});
}

/// Minimal BERT WordPiece tokenizer compatible with the `intfloat/e5-small-v2`
/// vocabulary shipped at `assets/models/e5/tokenizer.json`.
///
/// Not a full re-implementation of HuggingFace `tokenizers` — punctuation
/// splitting, Chinese char segmentation, and edge-case normalization are
/// simplified. Good enough for English voice logs; revisit if we see
/// quality regressions on an eval set.
class BertWordPieceTokenizer implements Tokenizer {
  BertWordPieceTokenizer._({
    required this.vocab,
    required this.reverseVocab,
    required this.clsId,
    required this.sepId,
    required this.padId,
    required this.unkId,
  });

  static const bool _lowercase = true;
  static const int _maxCharsPerWord = 100;

  /// Load a tokenizer from a HuggingFace `tokenizer.json`.
  static Future<Result<BertWordPieceTokenizer, TokenizerError>> load(
    String tokenizerJsonPath,
  ) async {
    try {
      final raw = await File(tokenizerJsonPath).readAsString();
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final model = parsed['model'] as Map<String, dynamic>? ?? const {};
      final vocab = model['vocab'] as Map<String, dynamic>? ?? const {};
      if (vocab.isEmpty) {
        return const Err(
          TokenizerLoadError(message: 'tokenizer.json has no vocab'),
        );
      }
      final Map<String, int> intVocab = vocab.map(
        (k, v) => MapEntry(k, v as int),
      );
      final reverse = <int, String>{
        for (final e in intVocab.entries) e.value: e.key,
      };

      int idOf(String token, int fallback) => intVocab[token] ?? fallback;

      return Ok(
        BertWordPieceTokenizer._(
          vocab: intVocab,
          reverseVocab: reverse,
          clsId: idOf('[CLS]', 101),
          sepId: idOf('[SEP]', 102),
          padId: idOf('[PAD]', 0),
          unkId: idOf('[UNK]', 100),
        ),
      );
    } on Object catch (e, s) {
      return Err(
        TokenizerLoadError(
          message: 'Failed to load tokenizer: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Token → id map from `tokenizer.json` → `model.vocab`.
  final Map<String, int> vocab;

  /// Id → token map.
  final Map<int, String> reverseVocab;

  final int clsId;
  final int sepId;
  final int padId;
  final int unkId;

  @override
  Tokens encode(String text, {int maxLength = 512}) {
    final words = _basicTokenize(text);
    final pieces = <int>[clsId];
    for (final word in words) {
      final wordPieces = _wordPiece(word);
      for (final piece in wordPieces) {
        if (pieces.length >= maxLength - 1) break;
        pieces.add(piece);
      }
      if (pieces.length >= maxLength - 1) break;
    }
    pieces.add(sepId);

    final inputIds = List<int>.from(pieces);
    final mask = List<int>.filled(inputIds.length, 1);
    // Pad to maxLength for fixed-shape ONNX inputs.
    while (inputIds.length < maxLength) {
      inputIds.add(padId);
      mask.add(0);
    }
    return Tokens(inputIds: inputIds, attentionMask: mask);
  }

  List<String> _basicTokenize(String text) {
    final normalized = _lowercase ? text.toLowerCase() : text;
    // Collapse whitespace and split on it. Punctuation becomes its own
    // token so `[CLS]` and `[SEP]` markers survive.
    final buf = StringBuffer();
    final out = <String>[];
    for (final ch in normalized.runes) {
      final c = String.fromCharCode(ch);
      if (_isWhitespace(c)) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      } else if (_isPunctuation(c)) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        out.add(c);
      } else {
        buf.write(c);
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  List<int> _wordPiece(String word) {
    if (word.length > _maxCharsPerWord) return [unkId];
    final out = <int>[];
    var start = 0;
    while (start < word.length) {
      var end = word.length;
      String? curPiece;
      while (start < end) {
        var sub = word.substring(start, end);
        if (start > 0) sub = '##$sub';
        if (vocab.containsKey(sub)) {
          curPiece = sub;
          break;
        }
        end--;
      }
      if (curPiece == null) return [unkId];
      out.add(vocab[curPiece]!);
      start = end;
    }
    return out;
  }

  bool _isWhitespace(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';

  bool _isPunctuation(String c) {
    final code = c.codeUnitAt(0);
    if ((code >= 33 && code <= 47) ||
        (code >= 58 && code <= 64) ||
        (code >= 91 && code <= 96) ||
        (code >= 123 && code <= 126)) {
      return true;
    }
    return false;
  }
}
