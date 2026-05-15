import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/log_summary_repository.dart';
import 'package:voxsynth/core/result.dart';

void main() {
  late VoxSynthDatabase db;
  late LogSummaryRepository repo;

  setUp(() {
    db = VoxSynthDatabase(NativeDatabase.memory());
    repo = LogSummaryRepository(db);
  });

  tearDown(() => db.close());

  LogSummaryWrite writeOf({
    String oneLiner = 'Discussed app launch planning with Raj.',
    List<String> bullets = const [
      'Investor deck needs updates.',
      'Launch target is next Friday.',
      'Raj will review pricing.',
    ],
    List<String> peopleProjects = const ['Raj'],
    List<String> decisions = const ['Launch target set to next Friday.'],
    List<String> followUps = const [
      'Update investor deck.',
      'Send Raj pricing draft.',
    ],
  }) {
    return LogSummaryWrite(
      oneLiner: oneLiner,
      bullets: bullets,
      peopleProjects: peopleProjects,
      decisions: decisions,
      followUps: followUps,
    );
  }

  test('upsert then findByLogId round-trips every field', () async {
    final res = await repo.upsert(logId: 'log_1', write: writeOf());
    expect(res, isA<Ok<LogSummaryView, LogSummaryRepositoryError>>());

    final found = await repo.findByLogId('log_1');
    expect(found, isNotNull);
    expect(found!.oneLiner, 'Discussed app launch planning with Raj.');
    expect(found.bullets, hasLength(3));
    expect(found.bullets.first, 'Investor deck needs updates.');
    expect(found.peopleProjects, ['Raj']);
    expect(found.decisions, ['Launch target set to next Friday.']);
    expect(found.followUps, [
      'Update investor deck.',
      'Send Raj pricing draft.',
    ]);
  });

  test('upsert replaces a prior row for the same log', () async {
    await repo.upsert(logId: 'log_1', write: writeOf());
    await repo.upsert(
      logId: 'log_1',
      write: writeOf(
        oneLiner: 'Updated note.',
        bullets: const ['New point.'],
        peopleProjects: const [],
        decisions: const [],
        followUps: const [],
      ),
    );

    final found = await repo.findByLogId('log_1');
    expect(found!.oneLiner, 'Updated note.');
    expect(found.bullets, ['New point.']);
    expect(found.peopleProjects, isEmpty);
    expect(found.decisions, isEmpty);
    expect(found.followUps, isEmpty);
  });

  test('findByLogId returns null when no row exists', () async {
    expect(await repo.findByLogId('missing'), isNull);
  });

  test('deleteForLog removes the row', () async {
    await repo.upsert(logId: 'log_1', write: writeOf());
    await repo.deleteForLog('log_1');
    expect(await repo.findByLogId('log_1'), isNull);
  });

  test('rows for different logs are isolated', () async {
    await repo.upsert(
      logId: 'log_1',
      write: writeOf(oneLiner: 'One.'),
    );
    await repo.upsert(
      logId: 'log_2',
      write: writeOf(oneLiner: 'Two.'),
    );
    expect((await repo.findByLogId('log_1'))!.oneLiner, 'One.');
    expect((await repo.findByLogId('log_2'))!.oneLiner, 'Two.');
  });
}
