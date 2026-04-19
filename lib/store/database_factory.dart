import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../core/errors.dart';
import '../core/result.dart';
import 'app_database.dart';
import 'database_key.dart';

/// Opens an [AppDatabase] for production use: SQLCipher-encrypted
/// database file under the app's documents directory, keyed from
/// [DatabaseKeyManager].
///
/// Tests should use [openInMemoryAppDatabase] instead — it builds a
/// Drift database on an ephemeral in-memory SQLite without touching
/// SQLCipher (whose native `libsqlcipher` isn't loaded in the
/// `flutter test` harness).
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
        // PRAGMA key is the SQLCipher handshake. `x'...'` expects raw
        // hex bytes (the DatabaseKeyManager already stores hex). This
        // must run before any other statement — sqlcipher_flutter_libs
        // takes over libsqlite3's symbol so plain `sqlite3.open` is
        // actually opening an encrypted DB when this pragma fires.
        db.execute("PRAGMA key = \"x'$keyHex'\"");
        // Harden a couple of knobs that matter for mobile use:
        // - `PRAGMA cipher_memory_security = OFF`: sqlcipher zeroes
        //   freed memory which is *nice* but wrecks throughput; our
        //   threat model is lost-device, not live memory scraping.
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

/// Opens an [AppDatabase] on an in-memory SQLite instance. Used by
/// repository tests — no file I/O, no SQLCipher, no secure-storage.
AppDatabase openInMemoryAppDatabase() {
  final executor = NativeDatabase.opened(
    sqlite3.openInMemory(),
    setup: (db) {
      db.execute('PRAGMA foreign_keys = ON');
    },
  );
  return AppDatabase(executor);
}
