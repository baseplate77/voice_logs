import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/processing_state.dart';
import 'package:voxsynth/core/db/repositories/transcript_segment_repository.dart';
import 'package:voxsynth/features/record/speech_recognizer.dart';

void main() {
  late VoxSynthDatabase db;
  late TranscriptSegmentRepository repo;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    repo = TranscriptSegmentRepository(db);
    await db
        .into(db.voiceLogs)
        .insert(
          VoiceLogsCompanion.insert(
            id: 'log-1',
            createdAt: DateTime.now().millisecondsSinceEpoch,
            durationMs: 30000,
            audioPath: 'audio/log-1.wav',
            rawTranscript: 'hello world',
            processingState: ProcessingState.recorded.wire,
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  test('persists and reads back word timings', () async {
    final segments = [
      const TranscriptSegmentResult(
        text: 'hello world',
        startMs: 0,
        endMs: 1000,
        words: [
          WordTiming(word: 'hello', startMs: 0, endMs: 400),
          WordTiming(word: 'world', startMs: 400, endMs: 1000),
        ],
      ),
    ];
    final res = await repo.replaceForLog(logId: 'log-1', segments: segments);
    expect(res.isOk, isTrue);

    final loaded = await repo.findByLogId('log-1');
    expect(loaded, hasLength(1));
    final stored = loaded.single;
    expect(stored.text, 'hello world');
    expect(stored.startMs, 0);
    expect(stored.endMs, 1000);
    expect(stored.words, hasLength(2));
    expect(stored.words.first.word, 'hello');
    expect(stored.words.last.endMs, 1000);
  });

  test('replaceForLog overwrites previous rows', () async {
    await repo.replaceForLog(
      logId: 'log-1',
      segments: [
        const TranscriptSegmentResult(
          text: 'first take',
          startMs: 0,
          endMs: 1000,
          words: [],
        ),
      ],
    );
    await repo.replaceForLog(
      logId: 'log-1',
      segments: [
        const TranscriptSegmentResult(
          text: 'second take',
          startMs: 0,
          endMs: 2000,
          words: [],
        ),
      ],
    );

    final loaded = await repo.findByLogId('log-1');
    expect(loaded, hasLength(1));
    expect(loaded.single.text, 'second take');
  });

  test('returns empty list for unknown log', () async {
    final loaded = await repo.findByLogId('not-in-db');
    expect(loaded, isEmpty);
  });

  test('handles segments without word timings', () async {
    await repo.replaceForLog(
      logId: 'log-1',
      segments: [
        const TranscriptSegmentResult(
          text: 'no timings here',
          startMs: 0,
          endMs: 5000,
          words: [],
        ),
      ],
    );
    final loaded = await repo.findByLogId('log-1');
    expect(loaded.single.words, isEmpty);
  });
}
