import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // On iOS voxsynth_asr is force-linked into the Runner binary (static pod
  // linkage + `-force_load` in the podspec), so there is no `voxsynth_asr`
  // dylib to dlopen — Rust symbols live in the current process. Host tests
  // and macOS builds dlopen the cdylib as usual.
  final ExternalLibrary? externalLibrary = Platform.isIOS
      ? ExternalLibrary.process(iKnowHowToUseIt: true)
      : null;
  await RustLib.init(externalLibrary: externalLibrary);
  runApp(const ProviderScope(child: VoxSynthApp()));
}
