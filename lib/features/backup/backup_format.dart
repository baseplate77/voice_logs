import 'dart:typed_data';

import 'backup_crypto.dart';

/// 16-byte magic header (`VOXSYNTH_BACKUP\0`) prefixing every blob so a
/// stray file picker pick can be rejected before any decryption attempt.
const List<int> kBackupMagic = [
  0x56, 0x4F, 0x58, 0x53, // V O X S
  0x59, 0x4E, 0x54, 0x48, // Y N T H
  0x5F, 0x42, 0x41, 0x43, // _ B A C
  0x4B, 0x55, 0x50, 0x00, // K U P \0
];

/// Backup file format revision. Bumped when the byte layout below changes
/// in a non-additive way. The schema version of the encrypted payload is
/// tracked separately inside the manifest.
const int kBackupFormatVersion = 1;

/// Bit flag inside the reserved field indicating audio files are bundled
/// in the encrypted ZIP. Currently always set when we export.
const int kFlagIncludesAudio = 0x01;

/// Header layout:
///
///   offset  length  field
///   0       16      magic ("VOXSYNTH_BACKUP\0")
///   16       4      format version (uint32 LE)
///   20       4      flags (uint32 LE)
///   24      16      PBKDF2 salt
///   40      12      AES-GCM nonce
///   52       4      ciphertext-with-tag length (uint32 LE)
///   56       N      ciphertext-with-tag bytes
const int kBackupHeaderBytes = 56;

/// Encode the header for an encrypted payload.
Uint8List encodeBackupHeader({
  required EncryptedPayload payload,
  required int flags,
}) {
  final header = ByteData(kBackupHeaderBytes);
  for (var i = 0; i < kBackupMagic.length; i++) {
    header.setUint8(i, kBackupMagic[i]);
  }
  header.setUint32(16, kBackupFormatVersion, Endian.little);
  header.setUint32(20, flags, Endian.little);
  for (var i = 0; i < kSaltBytes; i++) {
    header.setUint8(24 + i, payload.salt[i]);
  }
  for (var i = 0; i < kNonceBytes; i++) {
    header.setUint8(40 + i, payload.nonce[i]);
  }
  header.setUint32(52, payload.ciphertextWithTag.length, Endian.little);
  return header.buffer.asUint8List();
}

/// Parsed header — everything needed to feed back into [decrypt].
class BackupHeader {
  const BackupHeader({
    required this.formatVersion,
    required this.flags,
    required this.salt,
    required this.nonce,
    required this.ciphertextLength,
  });

  final int formatVersion;
  final int flags;
  final Uint8List salt;
  final Uint8List nonce;
  final int ciphertextLength;

  bool get includesAudio => (flags & kFlagIncludesAudio) != 0;
}

/// Parse a backup file's leading header. Throws [BackupFormatError] when
/// the magic mismatches, the version is in the future, or the file is
/// too short.
BackupHeader parseBackupHeader(Uint8List bytes) {
  if (bytes.length < kBackupHeaderBytes) {
    throw const BackupFormatError('File too short to be a VoxSynth backup.');
  }
  for (var i = 0; i < kBackupMagic.length; i++) {
    if (bytes[i] != kBackupMagic[i]) {
      throw const BackupFormatError('This file is not a VoxSynth backup.');
    }
  }
  final view = ByteData.sublistView(bytes, 0, kBackupHeaderBytes);
  final version = view.getUint32(16, Endian.little);
  if (version > kBackupFormatVersion) {
    throw BackupFormatError(
      'Backup format v$version is newer than this app (v$kBackupFormatVersion). '
      'Update the app and try again.',
    );
  }
  final flags = view.getUint32(20, Endian.little);
  final salt = Uint8List.sublistView(bytes, 24, 40);
  final nonce = Uint8List.sublistView(bytes, 40, 52);
  final ciphertextLength = view.getUint32(52, Endian.little);
  return BackupHeader(
    formatVersion: version,
    flags: flags,
    salt: salt,
    nonce: nonce,
    ciphertextLength: ciphertextLength,
  );
}

/// Thrown when a file isn't a recognisable backup (bad magic, version
/// from the future, truncated body). Distinct from [BackupAuthError]
/// which signals wrong-passphrase / tampered ciphertext.
class BackupFormatError implements Exception {
  const BackupFormatError(this.message);
  final String message;
  @override
  String toString() => 'BackupFormatError: $message';
}
