import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/backup/backup_crypto.dart';
import 'package:voxsynth/features/backup/backup_format.dart';

void main() {
  group('encode/parse backup header', () {
    test('roundtrips the salt, nonce, length, and flags', () {
      final payload = EncryptedPayload(
        salt: Uint8List(kSaltBytes)..[0] = 0xAA,
        nonce: Uint8List(kNonceBytes)..[5] = 0xBB,
        ciphertextWithTag: Uint8List(1234),
      );
      final header = encodeBackupHeader(
        payload: payload,
        flags: kFlagIncludesAudio,
      );
      expect(header.length, kBackupHeaderBytes);

      final parsed = parseBackupHeader(header);
      expect(parsed.formatVersion, kBackupFormatVersion);
      expect(parsed.includesAudio, isTrue);
      expect(parsed.salt, payload.salt);
      expect(parsed.nonce, payload.nonce);
      expect(parsed.ciphertextLength, 1234);
    });

    test('rejects files without the VOXSYNTH_BACKUP magic', () {
      final bogus = Uint8List(kBackupHeaderBytes); // all zeros
      expect(() => parseBackupHeader(bogus), throwsA(isA<BackupFormatError>()));
    });

    test('rejects files shorter than the header', () {
      expect(
        () => parseBackupHeader(Uint8List(10)),
        throwsA(isA<BackupFormatError>()),
      );
    });
  });
}
