import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/processing_state.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';

void main() {
  late VoxSynthDatabase db;
  late VoiceLogRepository repo;

  setUp(() {
    db = VoxSynthDatabase(NativeDatabase.memory());
    repo = VoiceLogRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('insertRecorded persists and find returns it', () async {
    final when = DateTime(2026, 4, 22, 12);
    final res = await repo.insertRecorded(
      id: 'log_1',
      createdAt: when,
      durationMs: 4321,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'hello world',
    );
    expect(res.isOk, isTrue);

    final fetched = await repo.find('log_1');
    expect(fetched, isNotNull);
    expect(fetched!.rawTranscript, 'hello world');
    expect(fetched.processingState, ProcessingState.recorded);
    expect(fetched.durationMs, 4321);
    expect(fetched.cleanedText, isNull);
  });

  test('watchAll emits reverse chronological order', () async {
    await repo.insertRecorded(
      id: 'a',
      createdAt: DateTime(2026, 4, 22, 10),
      durationMs: 1000,
      audioPath: 'a.wav',
      rawTranscript: 'older',
    );
    await repo.insertRecorded(
      id: 'b',
      createdAt: DateTime(2026, 4, 22, 12),
      durationMs: 1000,
      audioPath: 'b.wav',
      rawTranscript: 'newer',
    );

    final rows = await repo.watchAll().first;
    expect(rows.map((r) => r.id).toList(), ['b', 'a']);
  });
}
