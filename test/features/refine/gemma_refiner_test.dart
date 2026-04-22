import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/app_error.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/job_state.dart';
import 'package:voxsynth/core/db/processing_state.dart';
import 'package:voxsynth/core/db/repositories/entity_mention_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/core/worker/job_handler.dart';
import 'package:voxsynth/core/worker/job_queue.dart';
import 'package:voxsynth/features/refine/gemma_refiner.dart';
import 'package:voxsynth/features/refine/llm_runner.dart';

class _FakeLlm implements LlmRunner {
  _FakeLlm(this.responses);
  final List<String> responses;
  int i = 0;

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
  }) async => Ok(responses[i++]);

  @override
  Future<void> dispose() async {}
}

void main() {
  late VoxSynthDatabase db;
  late VoiceLogRepository logs;
  late EntityMentionRepository mentions;
  late JobQueue queue;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    logs = VoiceLogRepository(db);
    mentions = EntityMentionRepository(db);
    queue = JobQueue(db);
    await logs.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 4, 22),
      durationMs: 1000,
      audioPath: 'a.wav',
      rawTranscript: 'uh so i met shivani at cafe today',
    );
  });

  tearDown(() => db.close());

  test('happy path: parses, saves, enqueues embed', () async {
    final refiner = GemmaRefiner(
      runner: _FakeLlm([
        '{"cleaned_text":"I met Shivani at cafe today.","entities":[{"text":"Shivani","type":"PERSON"},{"text":"cafe","type":"PLACE"}]}',
      ]),
      voiceLogs: logs,
      mentions: mentions,
      queue: queue,
    );
    final res = await refiner.handle(
      const JobContext(jobId: 'j1', logId: 'log_1', attempts: 0),
    );
    expect(res, isA<Ok<JobOutcome, AppError>>());

    final log = await logs.find('log_1');
    expect(log!.cleanedText, 'I met Shivani at cafe today.');
    expect(log.processingState, ProcessingState.refined);

    final found = await mentions.forLog('log_1');
    expect(found, hasLength(2));
    expect(found.first.type, 'PERSON');

    // Embed job was enqueued.
    final next = await queue.claimNext();
    expect(next, isNotNull);
    expect(next!.jobType, JobType.embed);
  });

  test('bad JSON triggers one retry, then degrades to raw text', () async {
    final refiner = GemmaRefiner(
      runner: _FakeLlm(['not json', 'still not json']),
      voiceLogs: logs,
      mentions: mentions,
      queue: queue,
    );
    final res = await refiner.handle(
      const JobContext(jobId: 'j1', logId: 'log_1', attempts: 0),
    );
    expect(res, isA<Ok<JobOutcome, AppError>>());

    final log = await logs.find('log_1');
    expect(log!.processingState, ProcessingState.refined);
    expect(log.cleanedText, log.rawTranscript);
    expect(await mentions.forLog('log_1'), isEmpty);
  });
}
