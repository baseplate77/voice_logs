import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:voxsynth/core/db/database.dart';
import 'package:voxsynth/core/db/repositories/voice_log_repository.dart';
import 'package:voxsynth/features/backup/backup_applier.dart';
import 'package:voxsynth/features/backup/backup_reader.dart';
import 'package:voxsynth/features/backup/backup_snapshot.dart';
import 'package:voxsynth/features/backup/backup_writer.dart';

Directory _tmpDir() =>
    Directory.systemTemp.createTempSync('voxsynth_backup_test_');

void main() {
  test('snapshot → write → read → apply restores rows on a fresh DB', () async {
    final srcDocs = _tmpDir();
    final dstDocs = _tmpDir();
    addTearDown(() {
      try {
        srcDocs.deleteSync(recursive: true);
        dstDocs.deleteSync(recursive: true);
      } on Object {
        /* tolerate */
      }
    });

    // Seed the source DB with two voice logs (and a dummy WAV for one).
    final src = VoxSynthDatabase(NativeDatabase.memory());
    final srcRepo = VoiceLogRepository(src);
    addTearDown(src.close);

    final srcAudioDir = Directory(p.join(srcDocs.path, 'audio'))
      ..createSync(recursive: true);
    final wavPath = p.join(srcAudioDir.path, 'log-1.wav');
    File(wavPath).writeAsBytesSync(List<int>.filled(44, 0)); // dummy WAV bytes

    await srcRepo.insertRecorded(
      id: 'log-1',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1000),
      durationMs: 5000,
      audioPath: 'audio/log-1.wav',
      rawTranscript: 'first log',
    );
    await srcRepo.insertRecorded(
      id: 'log-2',
      createdAt: DateTime.fromMillisecondsSinceEpoch(2000),
      durationMs: 3000,
      audioPath: 'audio/missing.wav',
      rawTranscript: 'second log',
    );

    final snapshot = await readSnapshot(db: src, docsPath: srcDocs.path);
    expect(snapshot.voiceLogs, hasLength(2));
    expect(snapshot.audioFiles, hasLength(1)); // only log-1.wav exists

    final backupPath = p.join(srcDocs.path, 'backup.voxsynth');
    final writeResult = await writeBackup(
      snapshot: snapshot,
      passphrase: 'roundtrip-test-pass',
      outputPath: backupPath,
    );
    expect(writeResult.logCount, 2);
    expect(writeResult.audioFileCount, 1);
    expect(File(backupPath).existsSync(), isTrue);

    final decoded = await readBackup(
      path: backupPath,
      passphrase: 'roundtrip-test-pass',
    );
    expect(decoded.manifest['schema_version'], src.schemaVersion);
    expect(decoded.audioBytes.containsKey('log-1.wav'), isTrue);

    // Apply to an empty destination DB.
    final dst = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(dst.close);
    final report = await applyBackup(
      backup: decoded,
      db: dst,
      docsPath: dstDocs.path,
    );
    expect(report.tableCounts['voice_logs']?.inserted, 2);
    expect(report.audioFilesRestored, 1);

    final dstRepo = VoiceLogRepository(dst);
    final fetched1 = await dstRepo.find('log-1');
    final fetched2 = await dstRepo.find('log-2');
    expect(fetched1?.rawTranscript, 'first log');
    expect(fetched2?.rawTranscript, 'second log');

    // Audio file should now exist under the destination docs dir.
    expect(
      File(p.join(dstDocs.path, 'audio', 'log-1.wav')).existsSync(),
      isTrue,
    );
  });

  test('apply with duplicate ids reports skips rather than failing', () async {
    final srcDocs = _tmpDir();
    final dstDocs = _tmpDir();
    addTearDown(() {
      try {
        srcDocs.deleteSync(recursive: true);
        dstDocs.deleteSync(recursive: true);
      } on Object {
        /* tolerate */
      }
    });

    final src = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(src.close);
    final srcRepo = VoiceLogRepository(src);
    await srcRepo.insertRecorded(
      id: 'shared-id',
      createdAt: DateTime.fromMillisecondsSinceEpoch(1),
      durationMs: 1000,
      audioPath: 'audio/shared.wav',
      rawTranscript: 'from source',
    );
    final snapshot = await readSnapshot(db: src, docsPath: srcDocs.path);
    final backupPath = p.join(srcDocs.path, 'backup.voxsynth');
    await writeBackup(
      snapshot: snapshot,
      passphrase: 'pw',
      outputPath: backupPath,
    );

    final dst = VoxSynthDatabase(NativeDatabase.memory());
    addTearDown(dst.close);
    final dstRepo = VoiceLogRepository(dst);
    // Seed destination with a row sharing the same id.
    await dstRepo.insertRecorded(
      id: 'shared-id',
      createdAt: DateTime.fromMillisecondsSinceEpoch(99),
      durationMs: 9999,
      audioPath: 'audio/shared.wav',
      rawTranscript: 'pre-existing on destination',
    );

    final decoded = await readBackup(path: backupPath, passphrase: 'pw');
    final report = await applyBackup(
      backup: decoded,
      db: dst,
      docsPath: dstDocs.path,
    );
    expect(report.tableCounts['voice_logs']?.inserted, 0);
    expect(report.tableCounts['voice_logs']?.skipped, 1);

    final survivor = await dstRepo.find('shared-id');
    expect(survivor?.rawTranscript, 'pre-existing on destination');
  });
}
