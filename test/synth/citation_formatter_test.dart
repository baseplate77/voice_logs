import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/retrieve/models/ranked_chunk.dart';
import 'package:voxsynth/store/models/voice_log_record.dart';
import 'package:voxsynth/synth/citation_formatter.dart';
import 'package:voxsynth/synth/multi_hop_retriever.dart';

ChunkRecord _chunk(int id, String text) => ChunkRecord(
      id: id,
      logId: VoiceLogId('log-$id'),
      text: text,
      startChar: 0,
      endChar: text.length,
      topicHint: 'x',
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      objectboxId: 0,
    );

RankedChunk _ranked(int id, String text) => RankedChunk(
      chunk: _chunk(id, text),
      fusedScore: 1.0,
      rrfScore: 1.0,
      rerankScore: double.nan,
      timeDecayFactor: 1.0,
    );

void main() {
  group('formatChunksForPrompt', () {
    test('empty input → empty block + empty map', () {
      final r = formatChunksForPrompt(const <RankedChunk>[]);
      expect(r.block, '');
      expect(r.tagToChunkId, isEmpty);
    });

    test('tags chunks [C1]..[Cn] in order', () {
      final r = formatChunksForPrompt(<RankedChunk>[
        _ranked(10, 'first'),
        _ranked(20, 'second'),
        _ranked(30, 'third'),
      ]);
      expect(r.block, contains('[C1] first'));
      expect(r.block, contains('[C2] second'));
      expect(r.block, contains('[C3] third'));
      expect(r.tagToChunkId, <String, int>{
        'C1': 10,
        'C2': 20,
        'C3': 30,
      });
    });

    test('truncates chunks longer than the max with an ellipsis', () {
      final long = 'x' * (kChunkMaxCharsInPrompt + 50);
      final r = formatChunksForPrompt(<RankedChunk>[_ranked(1, long)]);
      expect(r.block, endsWith('…'));
      // Block length: "[C1] " (5) + maxChars + "…" (1) — give or take
      // trim.
      expect(r.block.length, lessThan(long.length + 10));
    });

    test('separates chunks with a blank line so the LLM can tokenize '
        'boundaries', () {
      final r = formatChunksForPrompt(<RankedChunk>[
        _ranked(1, 'a'),
        _ranked(2, 'b'),
      ]);
      expect(r.block.contains('\n\n[C2]'), isTrue);
    });
  });

  group('formatRecordsForPrompt', () {
    test('handles ChunkRecord inputs the same way', () {
      final r = formatRecordsForPrompt(<ChunkRecord>[
        _chunk(5, 'hello'),
        _chunk(6, 'world'),
      ]);
      expect(r.tagToChunkId, <String, int>{'C1': 5, 'C2': 6});
      expect(r.block, contains('[C1] hello'));
      expect(r.block, contains('[C2] world'));
    });
  });

  group('formatWeekClustersForPrompt', () {
    test('empty → empty block + empty map', () {
      final r = formatWeekClustersForPrompt(const <WeekCluster>[]);
      expect(r.block, '');
      expect(r.tagToChunkId, isEmpty);
    });

    test('tags across weeks are globally sequential, one map per '
        'chunk id', () {
      final wkA = DateTime.utc(2026, 3, 30);
      final wkB = DateTime.utc(2026, 4, 13);
      final r = formatWeekClustersForPrompt(<WeekCluster>[
        WeekCluster(weekStart: wkA, chunks: <RankedChunk>[
          _ranked(11, 'week-a one'),
          _ranked(12, 'week-a two'),
        ]),
        WeekCluster(weekStart: wkB, chunks: <RankedChunk>[
          _ranked(21, 'week-b one'),
        ]),
      ]);
      expect(r.tagToChunkId, <String, int>{
        'C1': 11,
        'C2': 12,
        'C3': 21,
      });
      expect(r.block, contains('Week of 2026-03-30'));
      expect(r.block, contains('Week of 2026-04-13'));
      expect(r.block, contains('[C1] week-a one'));
      expect(r.block, contains('[C3] week-b one'));
    });

    test('truncates long chunks with an ellipsis', () {
      final long = 'x' * (kChunkMaxCharsInPrompt + 100);
      final r = formatWeekClustersForPrompt(<WeekCluster>[
        WeekCluster(
          weekStart: DateTime.utc(2026, 4, 13),
          chunks: <RankedChunk>[_ranked(1, long)],
        ),
      ]);
      expect(r.block, endsWith('…'));
    });
  });

  group('parseCitations', () {
    test('empty answer → empty citations', () {
      expect(
        parseCitations('', <String, int>{'C1': 1}),
        isEmpty,
      );
    });

    test('resolves [Cn] markers to chunk ids with span offsets', () {
      const answer = 'Paris is the capital [C1] of France.';
      final citations = parseCitations(answer, <String, int>{'C1': 42});
      expect(citations, hasLength(1));
      final c = citations.single;
      expect(c.tag, 'C1');
      expect(c.chunkId, 42);
      // answer.substring(c.spanStart, c.spanEnd) == '[C1]'
      expect(answer.substring(c.spanStart, c.spanEnd), '[C1]');
    });

    test('multiple citations arrive in textual order', () {
      const answer = 'First [C1] then [C2] later [C1].';
      final citations = parseCitations(
        answer,
        <String, int>{'C1': 10, 'C2': 20},
      );
      expect(citations, hasLength(3));
      expect(citations.map((c) => c.tag), <String>['C1', 'C2', 'C1']);
      // Offsets strictly increasing.
      for (var i = 0; i + 1 < citations.length; i++) {
        expect(
          citations[i].spanStart,
          lessThan(citations[i + 1].spanStart),
        );
      }
    });

    test('unknown tags (hallucinated) are silently skipped', () {
      const answer = 'Real [C1] and fake [C99].';
      final citations = parseCitations(answer, <String, int>{'C1': 1});
      expect(citations, hasLength(1));
      expect(citations.single.tag, 'C1');
    });

    test('markers without brackets are ignored', () {
      const answer = 'Plain C1 reference is not a citation.';
      expect(parseCitations(answer, <String, int>{'C1': 1}), isEmpty);
    });

    test('lowercase c is not treated as a citation', () {
      const answer = 'Some [c1] marker.';
      expect(parseCitations(answer, <String, int>{'C1': 1}), isEmpty);
    });
  });

  group('answerHasCitations', () {
    test('false for citation-free answers', () {
      expect(
        answerHasCitations('No citations here.', <String, int>{'C1': 1}),
        isFalse,
      );
    });

    test('true for answers with at least one resolvable marker', () {
      expect(
        answerHasCitations('See [C1].', <String, int>{'C1': 1}),
        isTrue,
      );
    });

    test('false when every marker is unknown', () {
      expect(
        answerHasCitations('See [C9].', <String, int>{'C1': 1}),
        isFalse,
      );
    });
  });
}
