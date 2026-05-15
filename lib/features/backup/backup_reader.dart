import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'backup_crypto.dart';
import 'backup_format.dart';

/// Decoded backup contents — the manifest JSON plus the raw bytes of any
/// bundled audio files keyed by their filename ("log_xxx.wav").
class DecodedBackup {
  const DecodedBackup({
    required this.formatVersion,
    required this.manifest,
    required this.audioBytes,
  });

  final int formatVersion;

  /// Parsed manifest.json. Schema version + tables.
  final Map<String, Object?> manifest;

  /// `<filename>` → raw WAV bytes. Empty when the backup didn't include
  /// audio.
  final Map<String, Uint8List> audioBytes;
}

/// Read [path], parse the header, derive the key from [passphrase], and
/// decrypt + unpack the ZIP. Throws [BackupFormatError] for bad files
/// and [BackupAuthError] for wrong-passphrase / tampered ciphertext.
Future<DecodedBackup> readBackup({
  required String path,
  required String passphrase,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw BackupFormatError('Backup file not found at $path');
  }
  final bytes = await file.readAsBytes();
  final header = parseBackupHeader(bytes);

  final ciphertextEnd = kBackupHeaderBytes + header.ciphertextLength;
  if (bytes.length < ciphertextEnd) {
    throw const BackupFormatError(
      'Backup file is truncated — ciphertext shorter than the header claims.',
    );
  }
  final ciphertextWithTag = Uint8List.sublistView(
    bytes,
    kBackupHeaderBytes,
    ciphertextEnd,
  );

  final zipBytes = decrypt(
    ciphertextWithTag: ciphertextWithTag,
    salt: header.salt,
    nonce: header.nonce,
    passphrase: passphrase,
  );

  final archive = ZipDecoder().decodeBytes(zipBytes);

  Map<String, Object?>? manifest;
  final audioBytes = <String, Uint8List>{};
  for (final entry in archive) {
    if (!entry.isFile) continue;
    if (entry.name == 'manifest.json') {
      manifest =
          jsonDecode(utf8.decode(entry.content as List<int>))
              as Map<String, Object?>;
    } else if (entry.name.startsWith('audio/')) {
      final filename = entry.name.substring('audio/'.length);
      if (filename.isEmpty) continue;
      audioBytes[filename] = Uint8List.fromList(entry.content as List<int>);
    }
  }
  if (manifest == null) {
    throw const BackupFormatError(
      'Backup is missing manifest.json — was it written by this app?',
    );
  }

  return DecodedBackup(
    formatVersion: header.formatVersion,
    manifest: manifest,
    audioBytes: audioBytes,
  );
}
