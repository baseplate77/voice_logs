import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/store/database_key.dart';

/// Deterministic Random stub — `Random.secure()` isn't mockable, but
/// the manager accepts any `Random`. Using `Random(seed)` gives a
/// reproducible byte sequence so tests can assert exact hex output.
Random _seededRng(int seed) => Random(seed);

void main() {
  group('DatabaseKeyManager', () {
    test('first call generates a 64-char hex string and persists it',
        () async {
      final storage = InMemorySecureStorage();
      final mgr = DatabaseKeyManager(storage: storage, rng: _seededRng(42));

      final first = await mgr.getOrCreate();
      expect(first.isOk, isTrue);
      final key = first.okOrNull!;
      expect(key.length, 64); // 32 bytes × 2 hex chars
      expect(RegExp(r'^[0-9a-f]{64}$').hasMatch(key), isTrue);

      final stored = await storage.read('voxsynth.db_key.v1');
      expect(stored, key);
    });

    test('second call returns the same key (no regeneration)',
        () async {
      final storage = InMemorySecureStorage();
      final mgr = DatabaseKeyManager(storage: storage, rng: _seededRng(1));
      final a = (await mgr.getOrCreate()).okOrNull!;
      final b = (await mgr.getOrCreate()).okOrNull!;
      expect(a, b);
    });

    test('regenerates when the stored value is malformed', () async {
      final storage = InMemorySecureStorage();
      await storage.write('voxsynth.db_key.v1', 'not-hex');
      final mgr = DatabaseKeyManager(storage: storage, rng: _seededRng(1));
      final k = (await mgr.getOrCreate()).okOrNull!;
      expect(k, isNot('not-hex'));
      expect(k.length, 64);
    });

    test('regenerates when the stored value is the wrong length',
        () async {
      final storage = InMemorySecureStorage();
      await storage.write('voxsynth.db_key.v1', 'abcdef'); // too short
      final mgr = DatabaseKeyManager(storage: storage, rng: _seededRng(1));
      final k = (await mgr.getOrCreate()).okOrNull!;
      expect(k.length, 64);
    });

    test('different seeds produce different keys', () async {
      final a = (await DatabaseKeyManager(
        storage: InMemorySecureStorage(),
        rng: _seededRng(1),
      ).getOrCreate())
          .okOrNull!;
      final b = (await DatabaseKeyManager(
        storage: InMemorySecureStorage(),
        rng: _seededRng(2),
      ).getOrCreate())
          .okOrNull!;
      expect(a, isNot(b));
    });

    test('forget wipes the stored key', () async {
      final storage = InMemorySecureStorage();
      final mgr = DatabaseKeyManager(storage: storage, rng: _seededRng(1));
      await mgr.getOrCreate();
      expect(await storage.read('voxsynth.db_key.v1'), isNotNull);
      await mgr.forget();
      expect(await storage.read('voxsynth.db_key.v1'), isNull);
    });

    test('custom storageKey is used', () async {
      final storage = InMemorySecureStorage();
      final mgr = DatabaseKeyManager(
        storage: storage,
        rng: _seededRng(1),
        storageKey: 'custom.key',
      );
      await mgr.getOrCreate();
      expect(await storage.read('custom.key'), isNotNull);
      expect(await storage.read('voxsynth.db_key.v1'), isNull);
    });
  });
}
