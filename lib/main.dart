import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';
import 'core/db/providers.dart';
import 'core/native_paths.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Resolve the documents path via our own MethodChannel instead of
  // `path_provider`. path_provider_android's pigeon channel was raising
  // `channel-error` on this device even after `ensureInitialized`, so
  // we avoid the plugin entirely and talk to MainActivity directly.
  final docsPath = await const NativePaths().applicationDocumentsPath();
  runApp(
    ProviderScope(
      overrides: [appDocumentsPathProvider.overrideWithValue(docsPath)],
      child: const VoxSynthApp(),
    ),
  );
}
