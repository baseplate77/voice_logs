import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/errors.dart';
import '../core/result.dart';

/// Minimal contract around the platform secure-storage so tests can
/// swap in a fake without pulling in flutter_secure_storage's plugin
/// initialisation. `read` returns null when the key isn't present;
/// `write` overwrites silently.
abstract class SecureStorageBackend {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// Production adapter over `flutter_secure_storage`. iOS → Keychain
/// (encrypted by the Secure Enclave-backed class key),
/// Android → EncryptedSharedPreferences (AES-256 via the Android
/// Keystore when available).
class PlatformSecureStorage implements SecureStorageBackend {
  PlatformSecureStorage([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// Manages the 32-byte master key used to encrypt the VoxSynth Drift
/// database via SQLCipher.
///
/// First launch: generate 32 cryptographically-random bytes, hex-encode
/// them, and persist via [SecureStorageBackend]. Subsequent launches:
/// read the hex back and decode.
///
/// Why hex (not base64): SQLCipher's `PRAGMA key = "x'...'";` takes a
/// raw hex string. Storing in the same form skips a re-encode step on
/// hot path.
class DatabaseKeyManager {
  DatabaseKeyManager({
    SecureStorageBackend? storage,
    Random? rng,
    this.storageKey = _defaultStorageKey,
  })  : _storage = storage ?? PlatformSecureStorage(),
        _rng = rng ?? Random.secure();

  static const String _defaultStorageKey = 'voxsynth.db_key.v1';

  final SecureStorageBackend _storage;
  final Random _rng;
  final String storageKey;

  /// Key length in bytes. 32 = 256 bits (SQLCipher's default for
  /// AES-256).
  static const int keyLength = 32;

  /// Read the existing key, or generate + persist a new one. Hex string
  /// with no `0x` prefix and no spaces.
  Future<Result<String, AppError>> getOrCreate() async {
    try {
      final existing = await _storage.read(storageKey);
      if (existing != null && _isValidHex(existing)) {
        return Ok<String, AppError>(existing);
      }
      final bytes = _randomBytes(keyLength);
      final hex = _toHex(bytes);
      await _storage.write(storageKey, hex);
      return Ok<String, AppError>(hex);
    } on Object catch (e, st) {
      return Err<String, AppError>(
        StorageError(
          'failed to read or generate db key',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  /// Wipes the stored key — next launch will generate a fresh one.
  /// Exposed mostly for teardown in tests; reaching for this in app
  /// code means the database is about to be unreadable forever, so
  /// callers should also delete the DB file.
  Future<void> forget() async {
    await _storage.delete(storageKey);
  }

  Uint8List _randomBytes(int n) {
    final out = Uint8List(n);
    for (var i = 0; i < n; i++) {
      out[i] = _rng.nextInt(256);
    }
    return out;
  }

  static String _toHex(Uint8List bytes) {
    final buf = StringBuffer();
    for (final b in bytes) {
      buf.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return buf.toString();
  }

  static bool _isValidHex(String s) {
    if (s.length != keyLength * 2) return false;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      final ok = (c >= 0x30 && c <= 0x39) || // 0-9
          (c >= 0x61 && c <= 0x66) || // a-f
          (c >= 0x41 && c <= 0x46); // A-F
      if (!ok) return false;
    }
    return true;
  }
}

/// In-memory [SecureStorageBackend] for unit tests. Not exported from
/// `lib/` — lives here next to the real backend so tests can import a
/// matched pair.
class InMemorySecureStorage implements SecureStorageBackend {
  final Map<String, String> _data = <String, String>{};

  @override
  Future<String?> read(String key) async => _data[key];

  @override
  Future<void> write(String key, String value) async {
    _data[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}
