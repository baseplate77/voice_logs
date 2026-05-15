import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart' as pc;

/// AES-256-GCM authenticated encryption with PBKDF2-SHA256 key derivation.
///
/// All backup payloads are protected with a passphrase the user supplies —
/// nothing the app generates can decrypt a backup without it. The format
/// is deliberately boring: industry-standard primitives, large iteration
/// count, single derivation function. The audit story is "we did the
/// recommended thing."

/// OWASP 2024 PBKDF2-SHA256 recommendation for ~1s of CPU on a phone.
/// Higher means slower derive (good for the attacker, bad for legit
/// users); lower means faster. This is the knob most likely to need
/// retuning if real devices feel sluggish on export/import.
const int kPbkdf2Iterations = 600000;

/// AES-256 key, in bytes.
const int kKeyBytes = 32;

/// Salt for PBKDF2, in bytes.
const int kSaltBytes = 16;

/// GCM nonce ("IV"), in bytes. NIST recommends 96-bit nonces.
const int kNonceBytes = 12;

/// GCM authentication tag, in bytes. 128-bit tag is the standard choice.
const int kTagBytes = 16;

/// Output of [encrypt]. The salt + nonce + ciphertext + tag together are
/// everything needed to decrypt with the same passphrase.
class EncryptedPayload {
  const EncryptedPayload({
    required this.salt,
    required this.nonce,
    required this.ciphertextWithTag,
  });

  /// PBKDF2 salt. Random per encryption.
  final Uint8List salt;

  /// AES-GCM nonce. Random per encryption.
  final Uint8List nonce;

  /// Ciphertext concatenated with the 16-byte GCM auth tag — the layout
  /// pointycastle emits and consumes.
  final Uint8List ciphertextWithTag;
}

/// Encrypt [plaintext] with a fresh salt + nonce derived for [passphrase].
/// The caller is responsible for persisting the salt + nonce alongside
/// the ciphertext — without them, decryption is impossible.
EncryptedPayload encrypt({
  required Uint8List plaintext,
  required String passphrase,
  Random? random,
}) {
  if (passphrase.isEmpty) {
    throw ArgumentError.value(passphrase, 'passphrase', 'must not be empty');
  }
  final rng = random ?? Random.secure();
  final salt = _randomBytes(rng, kSaltBytes);
  final nonce = _randomBytes(rng, kNonceBytes);
  final key = _deriveKey(passphrase: passphrase, salt: salt);

  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(
      true,
      pc.AEADParameters(
        pc.KeyParameter(key),
        kTagBytes * 8,
        nonce,
        Uint8List(0),
      ),
    );
  final ciphertextWithTag = cipher.process(plaintext);

  return EncryptedPayload(
    salt: salt,
    nonce: nonce,
    ciphertextWithTag: ciphertextWithTag,
  );
}

/// Decrypt [ciphertextWithTag] using [passphrase], [salt], and [nonce].
/// Throws [BackupAuthError] on wrong passphrase or tampered ciphertext —
/// pointycastle surfaces that as InvalidCipherTextException internally.
Uint8List decrypt({
  required Uint8List ciphertextWithTag,
  required Uint8List salt,
  required Uint8List nonce,
  required String passphrase,
}) {
  if (salt.length != kSaltBytes) {
    throw ArgumentError.value(salt.length, 'salt.length');
  }
  if (nonce.length != kNonceBytes) {
    throw ArgumentError.value(nonce.length, 'nonce.length');
  }
  if (ciphertextWithTag.length < kTagBytes) {
    throw const BackupAuthError('Ciphertext shorter than the auth tag.');
  }
  final key = _deriveKey(passphrase: passphrase, salt: salt);
  final cipher = pc.GCMBlockCipher(pc.AESEngine())
    ..init(
      false,
      pc.AEADParameters(
        pc.KeyParameter(key),
        kTagBytes * 8,
        nonce,
        Uint8List(0),
      ),
    );
  try {
    return cipher.process(ciphertextWithTag);
  } on pc.InvalidCipherTextException {
    throw const BackupAuthError(
      'Wrong passphrase or backup file is corrupted.',
    );
  }
}

/// Derive a 32-byte AES key from [passphrase] + [salt] via PBKDF2-SHA256.
Uint8List _deriveKey({required String passphrase, required Uint8List salt}) {
  final params = pc.Pbkdf2Parameters(salt, kPbkdf2Iterations, kKeyBytes);
  final pbkdf2 = pc.PBKDF2KeyDerivator(pc.HMac(pc.SHA256Digest(), 64))
    ..init(params);
  return pbkdf2.process(Uint8List.fromList(utf8.encode(passphrase)));
}

Uint8List _randomBytes(Random rng, int n) {
  final out = Uint8List(n);
  for (var i = 0; i < n; i++) {
    out[i] = rng.nextInt(256);
  }
  return out;
}

/// Thrown by [decrypt] when authentication fails — wrong passphrase or
/// the ciphertext has been tampered with. Distinguishing the two is not
/// possible by design (that's the point of authenticated encryption).
class BackupAuthError implements Exception {
  const BackupAuthError(this.message);
  final String message;
  @override
  String toString() => 'BackupAuthError: $message';
}
