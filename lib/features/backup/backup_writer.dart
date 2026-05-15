import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'backup_crypto.dart';
import 'backup_format.dart';
import 'backup_snapshot.dart';

/// Result of [writeBackup] — the on-disk path plus a few stats the export
/// screen surfaces to the user ("12 logs, 84 MB, 32 audio files").
class BackupWriteResult {
  const BackupWriteResult({
    required this.filePath,
    required this.totalBytes,
    required this.logCount,
    required this.audioFileCount,
  });

  final String filePath;
  final int totalBytes;
  final int logCount;
  final int audioFileCount;
}

/// Build a `.voxsynth` backup file at [outputPath] from [snapshot].
///
/// Layout written to disk:
///   1. 56-byte header (see `backup_format.dart`)
///   2. AES-256-GCM ciphertext + 16-byte auth tag of a ZIP that contains:
///        - `manifest.json` — every table dumped to JSON
///        - `audio/<filename>.wav` — each audio file referenced by [snapshot]
Future<BackupWriteResult> writeBackup({
  required BackupSnapshot snapshot,
  required String passphrase,
  required String outputPath,
}) async {
  final archive = Archive();

  final manifestBytes = utf8.encode(jsonEncode(snapshot.toManifestJson()));
  archive.addFile(
    ArchiveFile('manifest.json', manifestBytes.length, manifestBytes),
  );

  for (final audioPath in snapshot.audioFiles) {
    final file = File(audioPath);
    if (!file.existsSync()) continue;
    final bytes = await file.readAsBytes();
    final name = 'audio/${p.basename(audioPath)}';
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive));
  final encrypted = encrypt(plaintext: zipBytes, passphrase: passphrase);

  final header = encodeBackupHeader(
    payload: encrypted,
    flags: kFlagIncludesAudio,
  );

  final out = File(outputPath);
  final sink = out.openWrite();
  try {
    sink.add(header);
    sink.add(encrypted.ciphertextWithTag);
    await sink.flush();
  } finally {
    await sink.close();
  }

  final totalBytes = await out.length();
  return BackupWriteResult(
    filePath: outputPath,
    totalBytes: totalBytes,
    logCount: snapshot.voiceLogs.length,
    audioFileCount: snapshot.audioFiles.length,
  );
}
