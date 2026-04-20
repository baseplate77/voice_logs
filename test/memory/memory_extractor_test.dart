import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/llm/llm_runner.dart';
import 'package:voxsynth/llm/models/cleaned_transcript.dart';
import 'package:voxsynth/memory/memory_extractor.dart';
import 'package:voxsynth/memory/models/memory.dart';
import 'package:voxsynth/store/models/voice_log_record.dart';

ChunkRecord _chunk(int id, String text) => ChunkRecord(
      id: id,
      logId: const VoiceLogId('log-1'),
      text: text,
      startChar: 0,
      endChar: text.length,
      topicHint: 't',
      createdAt: DateTime.utc(2026, 4, 18),
      objectboxId: 0,
    );

CleanedTranscript _cleaned(String text, List<ChunkRecord> chunks) =>
    CleanedTranscript(
      text: text,
      chunks: chunks
          .map((c) => TopicChunk(
                text: c.text,
                startChar: c.startChar,
                endChar: c.endChar,
                topicHint: c.topicHint,
              ))
          .toList(),
      entities: const <Entity>[],
      tags: const <String>[],
    );

void main() {
  group('MemoryExtractor', () {
    test('parses a well-formed JSON payload across all four kinds',
        () async {
      const payload = '''
{
  "facts": [
    {"title": "works at Acme", "content": "I work at Acme as a senior PM.",
     "confidence": 0.9, "entity_names": ["Acme"]}
  ],
  "decisions": [
    {"title": "postgres over mysql",
     "content": "Decided to migrate to Postgres.",
     "occurred_at": "2026-04-10", "confidence": 0.85, "entity_names": []}
  ],
  "episodes": [
    {"title": "1:1 with Priya", "content": "Tough conversation about scope.",
     "occurred_at": "2026-04-15", "confidence": 0.75, "entity_names": []}
  ],
  "goals": [
    {"title": "ship v1", "content": "Ship VoxSynth v1.",
     "state": "in_progress", "due_at": "2026-06-01",
     "confidence": 0.8, "entity_names": []}
  ]
}
''';
      final runner = FakeLlmRunner(responses: <String>[payload]);
      await runner.load();
      final extractor = MemoryExtractor(
        runner: runner,
        clock: () => DateTime.utc(2026, 4, 20),
      );

      final chunks = <ChunkRecord>[
        _chunk(1, 'I work at Acme as a senior PM discussing Postgres.'),
      ];
      final r = await extractor.extract(
        cleaned: _cleaned(chunks.first.text, chunks),
        chunks: chunks,
      );
      expect(r.isOk, isTrue);
      final candidates = r.okOrNull!;
      expect(candidates.length, 4);
      expect(candidates.map((c) => c.kind), <MemoryKind>{
        MemoryKind.fact,
        MemoryKind.decision,
        MemoryKind.episode,
        MemoryKind.goal,
      });
      final fact = candidates.firstWhere((c) => c.kind == MemoryKind.fact);
      expect(fact.sourceChunkIds, isNotEmpty);
      expect(fact.entityNames, <String>['Acme']);
    });

    test('retries once on malformed JSON and succeeds on retry', () async {
      const bad = 'Here is your result: not JSON';
      const good = '{"facts":[{"title":"a","content":"b","confidence":0.9,'
          '"entity_names":[]}],"decisions":[],"episodes":[],"goals":[]}';
      final runner = FakeLlmRunner(responses: <String>[bad, good]);
      await runner.load();
      final extractor = MemoryExtractor(runner: runner);
      final r = await extractor.extract(
        cleaned: _cleaned('t', <ChunkRecord>[_chunk(1, 't')]),
        chunks: <ChunkRecord>[_chunk(1, 't')],
      );
      expect(r.isOk, isTrue);
      expect(r.okOrNull!.length, 1);
      expect(runner.callCount, 2);
    });

    test('returns empty list when both passes fail to parse', () async {
      final runner =
          FakeLlmRunner(responses: <String>['bad', 'still bad']);
      await runner.load();
      final extractor = MemoryExtractor(runner: runner);
      final r = await extractor.extract(
        cleaned: _cleaned('t', <ChunkRecord>[_chunk(1, 't')]),
        chunks: <ChunkRecord>[_chunk(1, 't')],
      );
      expect(r.isOk, isTrue);
      expect(r.okOrNull, isEmpty);
      expect(runner.callCount, 2);
    });

    test('drops low-confidence candidates', () async {
      const payload = '{"facts":[{"title":"a","content":"b","confidence":0.3,'
          '"entity_names":[]}],"decisions":[],"episodes":[],"goals":[]}';
      final runner = FakeLlmRunner(responses: <String>[payload]);
      await runner.load();
      final extractor = MemoryExtractor(runner: runner);
      final r = await extractor.extract(
        cleaned: _cleaned('t', <ChunkRecord>[_chunk(1, 't')]),
        chunks: <ChunkRecord>[_chunk(1, 't')],
      );
      expect(r.okOrNull, isEmpty);
    });

    test('decisions require a parseable occurred_at (falls back to '
        'recording date)', () async {
      const payload = '{"facts":[],"decisions":[{"title":"d","content":"c",'
          '"occurred_at":null,"confidence":0.9,"entity_names":[]}],'
          '"episodes":[],"goals":[]}';
      final runner = FakeLlmRunner(responses: <String>[payload]);
      await runner.load();
      final extractor = MemoryExtractor(
        runner: runner,
        clock: () => DateTime.utc(2026, 4, 20),
      );
      final r = await extractor.extract(
        cleaned: _cleaned('t', <ChunkRecord>[_chunk(1, 't')]),
        chunks: <ChunkRecord>[_chunk(1, 't')],
      );
      expect(r.okOrNull!.length, 1);
      expect(r.okOrNull!.first.occurredAt, DateTime(2026, 4, 20));
    });
  });
}
