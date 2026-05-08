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
  int unloads = 0;

  @override
  Future<Result<void, LlmError>> load() async => const Ok(null);

  @override
  Future<Result<String, LlmError>> generate(
    String prompt, {
    double temperature = 0.3,
  }) async => Ok(responses[i++]);

  @override
  Future<void> unload() async {
    unloads++;
  }

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
    final llm = _FakeLlm([
      '{"cleaned_text":"I met Shivani at cafe today.","entities":[{"text":"Shivani","type":"PERSON"},{"text":"cafe","type":"PLACE"}]}',
    ]);
    final refiner = GemmaRefiner(
      runner: llm,
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

    // Embed job was enqueued. Gemma stays warm; idle TTL handles unload.
    final next = await queue.claimNext();
    expect(next, isNotNull);
    expect(next!.jobType, JobType.embed);
    expect(llm.unloads, 0);
  });

  test('long transcript is refined chunk by chunk and stitched', () async {
    await logs.insertRecorded(
      id: 'log_long',
      createdAt: DateTime(2026, 4, 23),
      durationMs: 60 * 60 * 1000,
      audioPath: 'long.wav',
      rawTranscript: 'met shivani at cafe then called arjun about atlas',
    );
    final llm = _FakeLlm([
      '{"cleaned_text":"Met Shivani at Cafe.","entities":[{"text":"Shivani","type":"PERSON"},{"text":"Cafe","type":"PLACE"}]}',
      '{"cleaned_text":"Cafe then called Arjun.","entities":[{"text":"Cafe","type":"PLACE"},{"text":"Arjun","type":"PERSON"}]}',
      '{"cleaned_text":"Arjun about Atlas.","entities":[{"text":"Arjun","type":"PERSON"},{"text":"Atlas","type":"PROJECT"}]}',
    ]);
    final refiner = GemmaRefiner(
      runner: llm,
      voiceLogs: logs,
      mentions: mentions,
      queue: queue,
      chunkTargetWords: 4,
      chunkOverlapWords: 1,
    );

    final res = await refiner.handle(
      const JobContext(jobId: 'j2', logId: 'log_long', attempts: 0),
    );
    expect(res, isA<Ok<JobOutcome, AppError>>());

    final log = await logs.find('log_long');
    expect(
      log!.cleanedText,
      'Met Shivani at Cafe. then called Arjun. about Atlas.',
    );
    expect(llm.i, 3);

    final found = await mentions.forLog('log_long');
    expect(found.map((m) => m.text).toList(), [
      'Shivani',
      'Cafe',
      'Arjun',
      'Atlas',
    ]);
    expect(found.last.charStart, log.cleanedText!.indexOf('Atlas'));
  });

  test('bad JSON triggers one retry, then degrades to raw text', () async {
    final llm = _FakeLlm(['not json', 'still not json']);
    final refiner = GemmaRefiner(
      runner: llm,
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
    expect(llm.unloads, 0);
  });
}
