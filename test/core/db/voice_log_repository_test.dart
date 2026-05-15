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
    expect(fetched.title, isNull);
    expect(fetched.displayTitle, 'hello world');
  });

  test('markRefined stores generated title', () async {
    await repo.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 4, 22, 12),
      durationMs: 4321,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'today i talked to raj about app launch',
    );

    final res = await repo.markRefined(
      id: 'log_1',
      cleanedText: 'Today I talked to Raj about the app launch.',
      title: 'Raj call about app launch',
    );
    expect(res.isOk, isTrue);

    final fetched = await repo.find('log_1');
    expect(fetched?.title, 'Raj call about app launch');
    expect(fetched?.displayTitle, 'Raj call about app launch');
  });

  test(
    'updateTitle stores trimmed value and overrides previous title',
    () async {
      await repo.insertRecorded(
        id: 'log_1',
        createdAt: DateTime(2026, 4, 22, 12),
        durationMs: 1000,
        audioPath: 'audio/log_1.wav',
        rawTranscript: 'hello world',
      );
      await repo.markRefined(
        id: 'log_1',
        cleanedText: 'Hello world.',
        title: 'auto title',
      );

      final res = await repo.updateTitle(
        id: 'log_1',
        title: '  user picked title  ',
      );
      expect(res.isOk, isTrue);

      final fetched = await repo.find('log_1');
      expect(fetched?.title, 'user picked title');
    },
  );

  test('updateTitle clears title when given empty/whitespace input', () async {
    await repo.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 4, 22, 12),
      durationMs: 1000,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'hello world',
    );
    await repo.markRefined(
      id: 'log_1',
      cleanedText: 'Hello world.',
      title: 'auto title',
    );

    final res = await repo.updateTitle(id: 'log_1', title: '   ');
    expect(res.isOk, isTrue);

    final fetched = await repo.find('log_1');
    expect(fetched?.title, isNull);
    expect(fetched?.displayTitle, 'Hello world.');
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
