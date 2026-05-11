import 'dart:convert';
import 'dart:io';

import '../../../core/app_error.dart';
import '../../../core/result.dart';
import 'chat_template.dart';

/// Errors surfaced from the BPE tokenizer.
sealed class BpeTokenizerError extends AppError {
  const BpeTokenizerError({required super.message, super.cause, super.stack});
}

/// Failed to read or parse `tokenizer.json` / `tokenizer_config.json`.
final class BpeTokenizerLoadError extends BpeTokenizerError {
  const BpeTokenizerLoadError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Failure during encoding (e.g. unknown special token).
final class BpeTokenizerEncodeError extends BpeTokenizerError {
  const BpeTokenizerEncodeError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// Byte-level BPE tokenizer compatible with HuggingFace `tokenizer.json`
/// for SmolLM2-360M-Instruct (and any GPT-2-style byte-level BPE).
///
/// Three encode entry points:
/// - [encode] for plain text (no special tokens injected).
/// - [encodeSegments] for ChatML prompts assembled from [ChatSegment]s.
/// - [decode] for streaming output, with optional special-token stripping.
///
/// The implementation follows the GPT-2 reference: pre-tokenize via a
/// fixed regex, map UTF-8 bytes to a printable unicode alphabet, then
/// greedily merge symbol pairs by their merge-table rank.
class BpeTokenizer {
  BpeTokenizer._({
    required this.vocab,
    required this.reverseVocab,
    required this.mergeRank,
    required this.specialTokens,
    required this.reverseSpecialTokens,
    required this.bosTokenId,
    required this.eosTokenId,
    required this.padTokenId,
  });

  /// String → token id for regular byte-level BPE pieces.
  final Map<String, int> vocab;

  /// Token id → string for [decode].
  final Map<int, String> reverseVocab;

  /// `'$a $b'` → priority. Lower rank = merged earlier.
  final Map<String, int> mergeRank;

  /// Special-token literal → id. Keys include `<|im_start|>`, `<|im_end|>`,
  /// `<|endoftext|>` and any other `added_tokens` flagged as special.
  final Map<String, int> specialTokens;

  /// Reverse of [specialTokens], for [decode] when special tokens are
  /// preserved.
  final Map<int, String> reverseSpecialTokens;

  /// Beginning-of-stream id (often `<|endoftext|>` for SmolLM2). Nullable
  /// because `tokenizer_config.json` may not declare one.
  final int? bosTokenId;

  /// End-of-stream id. SmolLM2-Instruct sets this to `<|im_end|>` so the
  /// chat template terminates each assistant turn.
  final int? eosTokenId;

  /// Padding id. Not used by causal decode but kept for completeness.
  final int? padTokenId;

  /// GPT-2 byte-to-unicode permutation. Computed once at load time.
  static final Map<int, String> _byteEncoder = _computeByteEncoder();

  /// Reverse of [_byteEncoder] for decoding.
  static final Map<String, int> _byteDecoder = {
    for (final e in _byteEncoder.entries) e.value: e.key,
  };

  /// Pre-tokenizer regex from the GPT-2 paper. Splits text into the
  /// units that BPE then merges within. `unicode: true` enables `\p{L}`
  /// and `\p{N}` Unicode property classes.
  static final RegExp _preTokenize = RegExp(
    r"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+",
    unicode: true,
  );

  /// Load a tokenizer from on-disk `tokenizer.json` and (optionally)
  /// `tokenizer_config.json`. The config file is consulted for
  /// bos/eos/pad token ids; missing it is non-fatal.
  static Future<Result<BpeTokenizer, BpeTokenizerError>> load({
    required String tokenizerJsonPath,
    String? tokenizerConfigPath,
  }) async {
    final tokenizerFile = File(tokenizerJsonPath);
    if (!tokenizerFile.existsSync()) {
      return Err(
        BpeTokenizerLoadError(
          message:
              'tokenizer.json not found at "$tokenizerJsonPath" — '
              'the SmolLM2 model assets are missing. Run '
              '`scripts/fetch_models.sh` from the repo root to download '
              'them, then rebuild the app.',
        ),
      );
    }
    try {
      final raw = await tokenizerFile.readAsString();
      final parsed = jsonDecode(raw) as Map<String, dynamic>;

      final model = parsed['model'] as Map<String, dynamic>?;
      if (model == null) {
        return const Err(
          BpeTokenizerLoadError(
            message: 'tokenizer.json missing "model" object',
          ),
        );
      }

      final rawVocab = model['vocab'];
      if (rawVocab is! Map) {
        return const Err(
          BpeTokenizerLoadError(
            message: 'tokenizer.json model.vocab is not a map',
          ),
        );
      }
      final vocab = <String, int>{};
      rawVocab.forEach((k, v) {
        if (k is String && v is int) vocab[k] = v;
      });

      final mergeRank = <String, int>{};
      final rawMerges = model['merges'];
      if (rawMerges is List) {
        for (var i = 0; i < rawMerges.length; i++) {
          final entry = rawMerges[i];
          String? merge;
          if (entry is String) {
            merge = entry;
          } else if (entry is List && entry.length == 2) {
            merge = '${entry[0]} ${entry[1]}';
          }
          if (merge != null) mergeRank[merge] = i;
        }
      }

      final specialTokens = <String, int>{};
      final reverseSpecial = <int, String>{};
      final addedTokens = parsed['added_tokens'];
      if (addedTokens is List) {
        for (final tok in addedTokens) {
          if (tok is! Map<String, dynamic>) continue;
          final content = tok['content'];
          final id = tok['id'];
          final special = tok['special'];
          if (content is! String || id is! int) continue;
          if (special == false) continue;
          specialTokens[content] = id;
          reverseSpecial[id] = content;
        }
      }

      final reverseVocab = <int, String>{
        for (final e in vocab.entries) e.value: e.key,
      };

      int? eosId;
      int? bosId;
      int? padId;

      if (tokenizerConfigPath != null) {
        try {
          final cfg = jsonDecode(
            await File(tokenizerConfigPath).readAsString(),
          );
          if (cfg is Map<String, dynamic>) {
            eosId = _resolveSpecialId(cfg['eos_token'], specialTokens);
            bosId = _resolveSpecialId(cfg['bos_token'], specialTokens);
            padId = _resolveSpecialId(cfg['pad_token'], specialTokens);
          }
        } on Object {
          // Non-fatal: token ids fall back to specialTokens lookup below.
        }
      }
      eosId ??= specialTokens['<|im_end|>'] ?? specialTokens['<|endoftext|>'];
      bosId ??= specialTokens['<|im_start|>'] ?? specialTokens['<|endoftext|>'];

      return Ok(
        BpeTokenizer._(
          vocab: vocab,
          reverseVocab: reverseVocab,
          mergeRank: mergeRank,
          specialTokens: specialTokens,
          reverseSpecialTokens: reverseSpecial,
          bosTokenId: bosId,
          eosTokenId: eosId,
          padTokenId: padId,
        ),
      );
    } on Object catch (e, s) {
      return Err(
        BpeTokenizerLoadError(
          message: 'Failed to load BPE tokenizer: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  /// Encode plain UTF-8 text. Special tokens in the string are NOT
  /// recognised — use [encodeSegments] for ChatML prompts.
  List<int> encode(String text) {
    final ids = <int>[];
    for (final match in _preTokenize.allMatches(text)) {
      final piece = match.group(0)!;
      final mapped = _byteEncode(piece);
      for (final symbol in _bpeMerge(mapped)) {
        final id = vocab[symbol];
        if (id != null) ids.add(id);
      }
    }
    return ids;
  }

  /// Encode a [ChatPrompt] segment list — special-token segments map to
  /// their reserved ids; text segments go through [encode].
  Result<List<int>, BpeTokenizerError> encodeSegments(
    List<ChatSegment> segments,
  ) {
    final ids = <int>[];
    for (final segment in segments) {
      switch (segment) {
        case ChatSpecial(:final token):
          final id = specialTokens[token];
          if (id == null) {
            return Err(
              BpeTokenizerEncodeError(
                message:
                    'Unknown special token "$token" — '
                    'check tokenizer.json added_tokens',
              ),
            );
          }
          ids.add(id);
        case ChatText(:final text):
          ids.addAll(encode(text));
      }
    }
    return Ok(ids);
  }

  /// Decode token ids back into text. By default, special tokens are
  /// dropped from the output (which is what callers want for streaming
  /// the assistant's reply); set [skipSpecial] to false to keep them as
  /// their literal form.
  String decode(Iterable<int> ids, {bool skipSpecial = true}) {
    final pieces = <String>[];
    for (final id in ids) {
      final special = reverseSpecialTokens[id];
      if (special != null) {
        if (!skipSpecial) pieces.add(special);
        continue;
      }
      final tok = reverseVocab[id];
      if (tok != null) pieces.add(tok);
    }
    return _byteDecode(pieces.join());
  }

  String _byteEncode(String piece) {
    final bytes = utf8.encode(piece);
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(_byteEncoder[b]);
    }
    return buf.toString();
  }

  String _byteDecode(String mapped) {
    final bytes = <int>[];
    for (final code in mapped.runes) {
      final char = String.fromCharCode(code);
      final b = _byteDecoder[char];
      if (b != null) {
        bytes.add(b);
      } else {
        bytes.addAll(utf8.encode(char));
      }
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  List<String> _bpeMerge(String mapped) {
    if (mapped.length < 2) return [mapped];
    var tokens = mapped.split('');

    while (tokens.length > 1) {
      var bestRank = 1 << 30;
      var bestIdx = -1;
      for (var i = 0; i < tokens.length - 1; i++) {
        final rank = mergeRank['${tokens[i]} ${tokens[i + 1]}'];
        if (rank != null && rank < bestRank) {
          bestRank = rank;
          bestIdx = i;
        }
      }
      if (bestIdx < 0) break;
      final merged = tokens[bestIdx] + tokens[bestIdx + 1];
      tokens = [
        ...tokens.sublist(0, bestIdx),
        merged,
        ...tokens.sublist(bestIdx + 2),
      ];
    }
    return tokens;
  }

  static int? _resolveSpecialId(Object? value, Map<String, int> specialTokens) {
    if (value is String) return specialTokens[value];
    if (value is Map<String, dynamic>) {
      final content = value['content'];
      if (content is String) return specialTokens[content];
    }
    return null;
  }

  static Map<int, String> _computeByteEncoder() {
    final bs = <int>[];
    for (var i = 0x21; i <= 0x7E; i++) {
      bs.add(i);
    }
    for (var i = 0xA1; i <= 0xAC; i++) {
      bs.add(i);
    }
    for (var i = 0xAE; i <= 0xFF; i++) {
      bs.add(i);
    }
    final cs = List<int>.from(bs);
    var n = 0;
    for (var b = 0; b < 256; b++) {
      if (!bs.contains(b)) {
        bs.add(b);
        cs.add(256 + n);
        n++;
      }
    }
    final out = <int, String>{};
    for (var i = 0; i < bs.length; i++) {
      out[bs[i]] = String.fromCharCode(cs[i]);
    }
    return out;
  }
}
