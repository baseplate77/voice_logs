import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../objectbox.g.dart';
import '../core/errors.dart';
import '../core/result.dart';
import 'app_database.dart';
import 'database_key.dart';

/// Opens an [AppDatabase] for production use: SQLCipher-encrypted
/// database file under the app's documents directory, keyed from
/// [DatabaseKeyManager].
///
/// Encryption is provided by SQLite3MultipleCiphers, bundled via
/// `package:sqlite3` 3.x build hooks (see the `hooks:` block in
/// pubspec.yaml selecting `source: sqlite3mc`). The old
/// `sqlcipher_flutter_libs` plugin is gone — no dynamic-library
/// override, no platform-specific dlopen dance. sqlite3mc speaks the
/// SQLCipher wire format when the `cipher = 'sqlcipher'` pragma is
/// set before the key, so existing on-disk databases open unchanged.
///
/// Tests should use [openInMemoryAppDatabase] instead — it builds a
/// Drift database on an ephemeral in-memory SQLite without the
/// encryption handshake.
Future<Result<AppDatabase, AppError>> openAppDatabase({
  required DatabaseKeyManager keyManager,
  String fileName = 'voxsynth.db',
}) async {
  try {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, fileName);

    final keyResult = await keyManager.getOrCreate();
    if (keyResult.isErr) {
      return Err<AppDatabase, AppError>(keyResult.errOrNull!);
    }
    final keyHex = keyResult.okOrNull!;

    final executor = NativeDatabase(
      File(path),
      setup: (db) {
        // The SQLite3MultipleCiphers handshake: select the cipher
        // scheme *before* supplying the key. `legacy = 4` matches
        // SQLCipher 4's page-format defaults (HMAC-SHA512, 256k
        // PBKDF2 iters), which is what `sqlcipher_flutter_libs`
        // used — keeps existing .db files readable across the
        // migration.
        db.execute("PRAGMA cipher = 'sqlcipher'");
        db.execute('PRAGMA legacy = 4');
        // `x'...'` supplies the 256-bit key as raw hex bytes; the
        // DatabaseKeyManager already stores hex.
        db.execute("PRAGMA key = \"x'$keyHex'\"");
        // - `cipher_memory_security = OFF`: sqlcipher zeroes freed
        //   memory which is nice but wrecks throughput; our threat
        //   model is lost-device, not live memory scraping.
        db.execute('PRAGMA cipher_memory_security = OFF');
        // - Plain sqlite pragmas for durability vs speed.
        db.execute('PRAGMA journal_mode = WAL');
        db.execute('PRAGMA synchronous = NORMAL');
        db.execute('PRAGMA foreign_keys = ON');
      },
    );
    return Ok<AppDatabase, AppError>(AppDatabase(executor));
  } on Object catch (e, st) {
    return Err<AppDatabase, AppError>(
      StorageError('failed to open app database', cause: e, stackTrace: st),
    );
  }
}

/// Open the ObjectBox store that backs the HNSW vector index.
///
/// Stored under `<app-documents>/voxsynth-vectors/`. ObjectBox needs
/// an exclusive lock on that directory, so the `Store` lives as long
/// as the app; callers pass it into [VoiceLogRepository].
Future<Result<Store, AppError>> openObjectBoxStore({
  String dirName = 'voxsynth-vectors',
}) async {
  try {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(appDir.path, dirName));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return Ok<Store, AppError>(await openStore(directory: dir.path));
  } on Object catch (e, st) {
    return Err<Store, AppError>(
      StorageError('failed to open ObjectBox store', cause: e, stackTrace: st),
    );
  }
}

/// Open a throw-away ObjectBox store in a fresh temp directory —
/// used by tests. Caller must close it (and rm the directory) when done.
Future<Store> openInMemoryObjectBoxStore() {
  final dir =
      Directory.systemTemp.createTempSync('voxsynth-objectbox-test-');
  return openStore(directory: dir.path);
}

/// Opens an [AppDatabase] on an in-memory SQLite instance. Used by
/// repository tests — no file I/O, no encryption handshake.
AppDatabase openInMemoryAppDatabase() {
  final executor = NativeDatabase.opened(
    sqlite3.openInMemory(),
    setup: (db) {
      db.execute('PRAGMA foreign_keys = ON');
    },
  );
  return AppDatabase(executor);
}
