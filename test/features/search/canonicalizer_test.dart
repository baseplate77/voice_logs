import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/canonical_entity_repository.dart';
import 'package:voxsynth/core/db/repositories/entity_mention_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/refine/offset_recovery.dart';
import 'package:voxsynth/features/search/canonicalizer.dart';
import 'package:voxsynth/features/search/embedder.dart';

/// Fake embedder that maps text to a pre-configured vector. Lets tests
/// control similarity outcomes precisely.
class _FakeEmbedder implements Embedder {
  _FakeEmbedder(this.byText);
  final Map<String, Float32List> byText;

  @override
  Future<Result<void, EmbedError>> load() async => const Ok(null);

  @override
  Future<Result<List<Embedding>, EmbedError>> embedPassages(
    List<String> texts,
  ) async {
    final out = <Embedding>[];
    for (final t in texts) {
      final clean = t.startsWith('passage: ') ? t.substring(9) : t;
      final match = byText.entries.firstWhere(
        (e) => clean.contains(e.key),
        orElse: () => MapEntry('', Float32List(2)),
      );
      out.add(Embedding(vector: match.value, dim: match.value.length));
    }
    return Ok(out);
  }

  @override
  Future<Result<Embedding, EmbedError>> embedQuery(String text) async =>
      throw UnimplementedError();

  @override
  Future<void> dispose() async {}
}

Float32List _unit(double x, double y) {
  final v = Float32List.fromList([x, y]);
  final norm = (x * x + y * y);
  if (norm == 0) return v;
  final n = 1.0 / _sqrt(norm);
  v[0] = x * n;
  v[1] = y * n;
  return v;
}

double _sqrt(double v) {
  var x = v;
  for (var i = 0; i < 10; i++) {
    x = (x + v / x) / 2;
  }
  return x;
}

void main() {
  late VoxSynthDatabase db;
  late CanonicalEntityRepository canon;
  late EntityMentionRepository mentions;
  late VoiceLogRepository logs;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    canon = CanonicalEntityRepository(db);
    mentions = EntityMentionRepository(db);
    logs = VoiceLogRepository(db);
    await logs.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 4, 22),
      durationMs: 1000,
      audioPath: 'a.wav',
      rawTranscript: '',
    );
  });

  tearDown(() => db.close());

  test('creates canonical entities on first pass', () async {
    const cleaned = 'I met Shivani at the cafe.';
    await mentions.replaceForLog(
      logId: 'log_1',
      mentions: const [
        LocatedMention(
          text: 'Shivani',
          type: 'PERSON',
          charStart: 6,
          charEnd: 13,
        ),
      ],
    );

    final canonicalizer = Canonicalizer(
      db: db,
      embedder: _FakeEmbedder({'Shivani': _unit(1, 0)}),
      mentions: mentions,
      canonicals: canon,
    );
    final res = await canonicalizer.canonicalizeLog(
      logId: 'log_1',
      cleanedText: cleaned,
    );
    expect(res.isOk, isTrue);

    final all = await canon.byType('PERSON');
    expect(all, hasLength(1));
    expect(all.first.displayName, 'Shivani');

    final updated = await mentions.forLog('log_1');
    expect(updated.first.canonicalEntityId, isNotNull);
  });

  test('links a similar mention to the existing canonical entity', () async {
    // First log creates the canonical entity.
    final v = _unit(1, 0);
    await canon.create(displayName: 'Shivani', type: 'PERSON', embedding: v);

    await mentions.replaceForLog(
      logId: 'log_1',
      mentions: const [
        LocatedMention(
          text: 'Shivani',
          type: 'PERSON',
          charStart: 0,
          charEnd: 7,
        ),
      ],
    );

    final canonicalizer = Canonicalizer(
      db: db,
      embedder: _FakeEmbedder({'Shivani': _unit(0.98, 0.2)}),
      mentions: mentions,
      canonicals: canon,
      threshold: 0.9,
    );
    await canonicalizer.canonicalizeLog(
      logId: 'log_1',
      cleanedText: 'Shivani came back.',
    );

    final all = await canon.byType('PERSON');
    expect(all, hasLength(1), reason: 'Should have reused existing entity');
    expect(all.first.mentionCount, 2);
  });
}
