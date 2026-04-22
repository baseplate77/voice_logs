import 'package:drift/drift.dart';

import '../../core/app_error.dart';
import '../../core/db/database.dart';
import '../../core/db/repositories/canonical_entity_repository.dart';
import '../../core/db/repositories/entity_mention_repository.dart';
import '../../core/logger.dart';
import '../../core/result.dart';
import 'embedder.dart';
import 'embedding_math.dart';

/// Threshold above which a mention is considered the same canonical
/// entity as an existing one. Hand-tuned from v1 eval; revisit with
/// real data once voice-logs accrue.
const double kCanonicalSimilarityThreshold = 0.82;

/// How many chars of left/right context to embed alongside the mention
/// surface. Context helps disambiguate e.g. "Apple" the company vs
/// "apple" the fruit.
const int kContextWindowChars = 60;

sealed class CanonicalizeError extends AppError {
  const CanonicalizeError({required super.message, super.cause, super.stack});
}

final class CanonicalizeEmbedError extends CanonicalizeError {
  const CanonicalizeEmbedError({
    required super.message,
    super.cause,
    super.stack,
  });
}

final class CanonicalizeDbError extends CanonicalizeError {
  const CanonicalizeDbError({required super.message, super.cause, super.stack});
}

/// Links entity mentions to canonical entities. Single pass per log:
/// for each mention, embed (surface + context), compare to existing
/// canonical entities of the same type, link if similarity crosses
/// threshold, create otherwise.
class Canonicalizer {
  Canonicalizer({
    required VoxSynthDatabase db,
    required Embedder embedder,
    required EntityMentionRepository mentions,
    required CanonicalEntityRepository canonicals,
    double threshold = kCanonicalSimilarityThreshold,
  }) : _db = db,
       _embedder = embedder,
       _mentions = mentions,
       _canonicals = canonicals,
       _threshold = threshold;

  final VoxSynthDatabase _db;
  final Embedder _embedder;
  final EntityMentionRepository _mentions;
  final CanonicalEntityRepository _canonicals;
  final double _threshold;

  final _log = Logger('canonicalizer');

  /// Canonicalize every mention for [logId].
  Future<Result<void, CanonicalizeError>> canonicalizeLog({
    required String logId,
    required String cleanedText,
  }) async {
    final mentions = await _mentions.forLog(logId);
    if (mentions.isEmpty) return const Ok(null);

    final contexts = mentions
        .map((m) => _withContext(cleanedText, m.charStart, m.charEnd))
        .toList();
    final embedded = await _embedder.embedPassages(contexts);
    switch (embedded) {
      case Err(:final error):
        return Err(
          CanonicalizeEmbedError(
            message: 'Failed to embed mentions: ${error.message}',
            cause: error.cause,
            stack: error.stack,
          ),
        );
      case Ok(:final value):
        try {
          for (var i = 0; i < mentions.length; i++) {
            final m = mentions[i];
            final vec = value[i].vector;
            final candidates = await _canonicals.byType(m.type);
            String? linkedId;
            var bestScore = _threshold;
            for (final cand in candidates) {
              final score = cosineSimilarity(cand.embedding, vec);
              if (score > bestScore) {
                bestScore = score;
                linkedId = cand.id;
              }
            }
            if (linkedId == null) {
              final res = await _canonicals.create(
                displayName: m.text,
                type: m.type,
                embedding: vec,
              );
              linkedId = switch (res) {
                Ok(:final value) => value,
                Err(:final error) => throw StateError(error.message),
              };
            } else {
              await _canonicals.incrementMentionCount(linkedId);
            }
            await (_db.update(
              _db.entityMentions,
            )..where((t) => t.id.equals(m.id))).write(
              EntityMentionsCompanion(canonicalEntityId: Value(linkedId)),
            );
          }
          _log.i('Canonicalized ${mentions.length} mentions for $logId');
          return const Ok(null);
        } on Object catch (e, s) {
          return Err(
            CanonicalizeDbError(
              message: 'Canonicalize failed: $e',
              cause: e,
              stack: s,
            ),
          );
        }
    }
  }

  String _withContext(String text, int charStart, int charEnd) {
    final left = (charStart - kContextWindowChars).clamp(0, text.length);
    final right = (charEnd + kContextWindowChars).clamp(0, text.length);
    return text.substring(left, right);
  }
}
