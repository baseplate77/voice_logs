import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/memory_repository.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/core/result.dart';
import 'package:voxsynth/features/memory/memory_types.dart';

void main() {
  late VoxSynthDatabase db;
  late VoiceLogRepository logs;
  late MemoryRepository memories;

  setUp(() async {
    db = VoxSynthDatabase(NativeDatabase.memory());
    logs = VoiceLogRepository(db);
    memories = MemoryRepository(db);
    await logs.insertRecorded(
      id: 'log_1',
      createdAt: DateTime(2026, 5, 7),
      durationMs: 1000,
      audioPath: 'audio/log_1.wav',
      rawTranscript: 'I am building VoxSynth.',
    );
  });

  tearDown(() => db.close());

  test(
    'createOrUpdate stores active normal memory with source evidence',
    () async {
      final res = await memories.createOrUpdate(
        candidate: const MemoryCandidate(
          type: MemoryType.project,
          text: 'User is building VoxSynth.',
          evidence: 'I am building VoxSynth',
          confidence: 0.91,
          sensitivity: MemorySensitivity.normal,
          startChar: 0,
          endChar: 22,
        ),
        sourceLogId: 'log_1',
        embedding: Float32List.fromList([1, 0]),
      );

      expect(res, isA<Ok<MemoryItemView, MemoryRepositoryError>>());
      final memory = (res as Ok<MemoryItemView, MemoryRepositoryError>).value;
      expect(memory.status, MemoryStatus.active);
      expect(memory.normalizedText, 'user is building voxsynth');

      final sourceCount = await db
          .customSelect('SELECT COUNT(*) AS c FROM memory_sources')
          .getSingle();
      expect(sourceCount.read<int>('c'), 1);
    },
  );

  test('sensitive memory remains candidate until confirmed', () async {
    final res = await memories.createOrUpdate(
      candidate: const MemoryCandidate(
        type: MemoryType.eventContext,
        text: 'User had a cardiology appointment today.',
        evidence: 'cardiology appointment',
        confidence: 0.96,
        sensitivity: MemorySensitivity.sensitive,
        startChar: 8,
        endChar: 31,
      ),
      sourceLogId: 'log_1',
      embedding: Float32List.fromList([0, 1]),
    );

    final memory = (res as Ok<MemoryItemView, MemoryRepositoryError>).value;
    expect(memory.status, MemoryStatus.candidate);

    final confirmed = await memories.confirm(memory.id);
    expect(confirmed.isOk, isTrue);
    final updated = await memories.find(memory.id);
    expect(updated!.status, MemoryStatus.active);
  });

  test('similar candidates dedupe and add source evidence', () async {
    final first = await memories.createOrUpdate(
      candidate: const MemoryCandidate(
        type: MemoryType.preference,
        text: 'User prefers local-first apps.',
        evidence: 'I prefer local-first apps',
        confidence: 0.75,
        sensitivity: MemorySensitivity.normal,
        startChar: 0,
        endChar: 25,
      ),
      sourceLogId: 'log_1',
      embedding: Float32List.fromList([1, 0]),
    );
    final firstMemory =
        (first as Ok<MemoryItemView, MemoryRepositoryError>).value;

    await logs.insertRecorded(
      id: 'log_2',
      createdAt: DateTime(2026, 5, 8),
      durationMs: 1000,
      audioPath: 'audio/log_2.wav',
      rawTranscript: 'I like private local apps.',
    );
    final second = await memories.createOrUpdate(
      candidate: const MemoryCandidate(
        type: MemoryType.preference,
        text: 'User likes private local apps.',
        evidence: 'I like private local apps',
        confidence: 0.78,
        sensitivity: MemorySensitivity.normal,
        startChar: 0,
        endChar: 25,
      ),
      sourceLogId: 'log_2',
      embedding: Float32List.fromList([0.99, 0.01]),
    );
    final secondMemory =
        (second as Ok<MemoryItemView, MemoryRepositoryError>).value;

    expect(secondMemory.id, firstMemory.id);
    expect(secondMemory.status, MemoryStatus.active);

    final sourceCount = await db
        .customSelect(
          'SELECT COUNT(*) AS c FROM memory_sources WHERE memory_id = ?',
          variables: [Variable<String>(firstMemory.id)],
        )
        .getSingle();
    expect(sourceCount.read<int>('c'), 2);
  });

  test(
    'deleting source log removes memories with no remaining evidence',
    () async {
      final res = await memories.createOrUpdate(
        candidate: const MemoryCandidate(
          type: MemoryType.project,
          text: 'User is building VoxSynth.',
          evidence: 'I am building VoxSynth',
          confidence: 0.91,
          sensitivity: MemorySensitivity.normal,
          startChar: 0,
          endChar: 22,
        ),
        sourceLogId: 'log_1',
        embedding: Float32List.fromList([1, 0]),
      );
      final memory = (res as Ok<MemoryItemView, MemoryRepositoryError>).value;

      final deleted = await logs.delete('log_1');
      expect(deleted.isOk, isTrue);
      expect(await memories.find(memory.id), isNull);
      expect(await logs.find('log_1'), isNull);
    },
  );

  test('delete removes memory-only rows but preserves source log', () async {
    final res = await memories.createOrUpdate(
      candidate: const MemoryCandidate(
        type: MemoryType.project,
        text: 'User is building VoxSynth.',
        evidence: 'I am building VoxSynth',
        confidence: 0.91,
        sensitivity: MemorySensitivity.normal,
        startChar: 0,
        endChar: 22,
      ),
      sourceLogId: 'log_1',
      embedding: Float32List.fromList([1, 0]),
    );
    final memory = (res as Ok<MemoryItemView, MemoryRepositoryError>).value;

    final deleted = await memories.delete(memory.id);
    expect(deleted.isOk, isTrue);
    expect(await memories.find(memory.id), isNull);
    expect(await logs.find('log_1'), isNotNull);
  });
}
