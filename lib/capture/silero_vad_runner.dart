// coverage:ignore-file
//
// SileroVadRunner will route Silero VAD inference through the Rust crate
// (`voxsynth_asr`) in a follow-on phase — sherpa-rs exposes Silero under
// `sherpa_rs::silero_vad`, so going via the same Rust bridge keeps a single
// ONNX Runtime in the app binary. Linking the `onnxruntime` pub.dev plugin
// alongside voxsynth_asr's statically-bundled ORT caused 21 duplicate-symbol
// errors at iOS link time (ORT's CoreML, XNNPACK, and ObjC classes collide).
//
// Until that Rust hookup lands, this is a stub. All VAD logic is unit-tested
// against `FakeVadRunner` (see `VadSegmenter` / `VadPipeline` tests). The
// production path (VadWorkerIsolate → SileroVadRunner) is itself
// coverage-ignored, so nothing in the test suite hits this stub.

import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';
import 'vad_runner.dart';

/// Placeholder Silero VAD runner. Real implementation pending Phase 2c+1:
/// Rust-side VAD via sherpa-rs.
class SileroVadRunner implements VadRunner {
  SileroVadRunner({required this.modelPath});

  final String modelPath;

  @override
  int get frameSize => 512;

  @override
  int get sampleRate => 16000;

  @override
  Future<Result<void, AppError>> load() async => Err<void, AppError>(
        ModelLoadError(
          modelPath,
          reason: 'SileroVadRunner stub — pending Rust sherpa-rs hookup',
        ),
      );

  @override
  Future<Result<double, AppError>> detect(Float32List frame) async =>
      const Err<double, AppError>(
        ModelLoadError(
          'silero',
          reason: 'SileroVadRunner.detect called on stub',
        ),
      );

  @override
  Future<void> reset() async {}

  @override
  Future<void> dispose() async {}
}
