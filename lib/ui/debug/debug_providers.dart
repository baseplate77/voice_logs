import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:objectbox/objectbox.dart' show Store;

import '../../core/errors.dart';
import '../../llm/gemma_runner.dart';
import '../../objectbox.g.dart' hide Entity;
import '../../store/app_database.dart';
import '../../store/database_factory.dart';
import '../../store/database_key.dart';
import '../../store/objectbox_entities.dart';
import '../../store/vector_index.dart';
import 'model_bootstrap.dart';

/// Providers that stay alive for the app's whole lifetime.
///
/// **Intentionally** excludes the three heavy Rust-backed runners
/// (Parakeet, E5, Gemma). Those are loaded on demand during post-
/// processing and disposed immediately after — one at a time — to keep
/// peak RAM below Android's per-app heap limit on 4 GB devices.
///
/// CaptureService is also excluded: it's built lazily inside
/// [DebugRunNotifier.start] so any platform-channel failure from the
/// `record` plugin surfaces on the record path, not during boot.
///
/// The always-alive set below is cheap: SQLCipher DB handle (~1 MB)
/// and ObjectBox (HNSW metadata only). Total static footprint <10 MB.

/// Fired by [modelPathsProvider] while copying the bundled models onto
/// disk. `null` before the bootstrap starts and after it finishes.
typedef BootstrapProgressState = ({
  String currentFile,
  int fileIndex,
  int totalFiles,
});

final bootstrapProgressProvider =
    StateProvider<BootstrapProgressState?>((ref) => null);

/// 0..100 during the Gemma 4 E2B download at startup. `null` before
/// download starts and after it completes.
final gemmaDownloadPercentProvider = StateProvider<int?>((ref) => null);

/// Copies all bundled model files to the documents directory on first
/// launch and returns their absolute paths. Subsequent runs short-circuit
/// on the file-size check inside [bootstrapModels].
final modelPathsProvider = FutureProvider<ModelPaths>((ref) async {
  return bootstrapModels(
    onProgress: (file, i, total) {
      ref.read(bootstrapProgressProvider.notifier).state = (
        currentFile: file,
        fileIndex: i,
        totalFiles: total,
      );
    },
  );
});

/// Copies the Gemma 4 E2B `.litertlm` bundle (~2.58 GB) out of the
/// Flutter asset tree into flutter_gemma's on-device cache. Does NOT
/// instantiate an [InferenceModel] — that happens lazily during the
/// cleanup stage to keep the RAM budget "one heavy model at a time".
/// Idempotent: once the file is cached, subsequent runs resolve in
/// milliseconds.
final gemmaWarmUpProvider = FutureProvider<void>((ref) async {
  final result = await GemmaRunner.warmUp(
    onInstallProgress: (percent) {
      ref.read(gemmaDownloadPercentProvider.notifier).state = percent;
    },
  );
  ref.read(gemmaDownloadPercentProvider.notifier).state = null;
  _throwOnErr(result.errOrNull);
});

/// Manages the SQLCipher master key (iOS Keychain / Android
/// EncryptedSharedPrefs). Synchronous — just instantiates a thin wrapper.
final databaseKeyManagerProvider =
    Provider<DatabaseKeyManager>((ref) => DatabaseKeyManager());

final appDatabaseProvider = FutureProvider<AppDatabase>((ref) async {
  final keyManager = ref.watch(databaseKeyManagerProvider);
  final result = await openAppDatabase(keyManager: keyManager);
  _throwOnErr(result.errOrNull);
  final db = result.okOrNull!;
  ref.onDispose(db.close);
  return db;
});

final objectboxStoreProvider = FutureProvider<Store>((ref) async {
  final result = await openObjectBoxStore();
  _throwOnErr(result.errOrNull);
  final store = result.okOrNull!;
  ref.onDispose(store.close);
  return store;
});

final vectorIndexProvider = FutureProvider<VectorIndex>((ref) async {
  final store = await ref.watch(objectboxStoreProvider.future);
  return ObjectBoxVectorIndex(store.box<ChunkVector>());
});

/// The "always-alive" handles the debug screen and run-notifier need at
/// rest. Heavy models (Parakeet, E5, Gemma) are *not* included — the
/// run-notifier loads and disposes them one at a time during post-
/// processing.
///
/// The [CaptureService] is *also* not included here: it's constructed
/// lazily inside [DebugRunNotifier.start] so that any platform-channel
/// failure (e.g. `record` plugin throwing "invalid argument") surfaces
/// when the user hits Record, not during the boot checklist.
class CoreRuntime {
  const CoreRuntime({
    required this.paths,
    required this.db,
    required this.vectorIndex,
  });

  final ModelPaths paths;
  final AppDatabase db;
  final VectorIndex vectorIndex;
}

final coreRuntimeProvider = FutureProvider<CoreRuntime>((ref) async {
  final paths = await ref.watch(modelPathsProvider.future);
  final db = await ref.watch(appDatabaseProvider.future);
  final vectorIndex = await ref.watch(vectorIndexProvider.future);
  // Block the record UI until Gemma is cached on device. The file is
  // downloaded once (~2.58 GB) and resolves instantly on subsequent
  // launches. No InferenceModel is held in RAM here — that happens
  // later in the cleanup stage.
  await ref.watch(gemmaWarmUpProvider.future);
  return CoreRuntime(
    paths: paths,
    db: db,
    vectorIndex: vectorIndex,
  );
});

void _throwOnErr(AppError? err) {
  if (err != null) throw err;
}
