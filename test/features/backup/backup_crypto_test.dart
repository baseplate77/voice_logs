import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/backup/backup_crypto.dart';

void main() {
  group('encrypt → decrypt roundtrip', () {
    test('recovers the exact plaintext with the right passphrase', () {
      final plaintext = Uint8List.fromList(utf8.encode('hello voxsynth'));
      final payload = encrypt(
        plaintext: plaintext,
        passphrase: 'correct-horse',
      );
      final recovered = decrypt(
        ciphertextWithTag: payload.ciphertextWithTag,
        salt: payload.salt,
        nonce: payload.nonce,
        passphrase: 'correct-horse',
      );
      expect(recovered, plaintext);
    });

    test('throws BackupAuthError on wrong passphrase', () {
      final plaintext = Uint8List.fromList(utf8.encode('payload'));
      final payload = encrypt(plaintext: plaintext, passphrase: 'real-one');
      expect(
        () => decrypt(
          ciphertextWithTag: payload.ciphertextWithTag,
          salt: payload.salt,
          nonce: payload.nonce,
          passphrase: 'wrong-one',
        ),
        throwsA(isA<BackupAuthError>()),
      );
    });

    test('throws BackupAuthError when ciphertext is tampered', () {
      final plaintext = Uint8List.fromList(utf8.encode('original'));
      final payload = encrypt(plaintext: plaintext, passphrase: 'key');
      final tampered = Uint8List.fromList(payload.ciphertextWithTag);
      tampered[0] ^= 0xFF; // flip a bit in the first ciphertext byte
      expect(
        () => decrypt(
          ciphertextWithTag: tampered,
          salt: payload.salt,
          nonce: payload.nonce,
          passphrase: 'key',
        ),
        throwsA(isA<BackupAuthError>()),
      );
    });

    test('rejects an empty passphrase up front', () {
      expect(
        () => encrypt(plaintext: Uint8List(0), passphrase: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('produces unique salt + nonce per call', () {
      final plaintext = Uint8List.fromList(utf8.encode('same input'));
      final a = encrypt(plaintext: plaintext, passphrase: 'pw');
      final b = encrypt(plaintext: plaintext, passphrase: 'pw');
      expect(a.salt, isNot(equals(b.salt)));
      expect(a.nonce, isNot(equals(b.nonce)));
      expect(a.ciphertextWithTag, isNot(equals(b.ciphertextWithTag)));
    });
  });
}
