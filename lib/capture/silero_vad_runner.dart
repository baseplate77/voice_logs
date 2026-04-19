// coverage:ignore-file
//
// SileroVadRunner wraps native ONNX Runtime bindings. Exercising it
// requires the real silero_vad.onnx model plus the onnxruntime shared
// libraries, which are not available inside `flutter test`. The shape
// of the class is validated by the VadRunner contract used in
// VadPipeline tests via FakeVadRunner; device/integration smoke tests
// are tracked for Phase 1 manual verification.

import 'dart:io';
import 'dart:typed_data';

import 'package:onnxruntime/onnxruntime.dart';

import '../core/errors.dart';
import '../core/result.dart';
import 'vad_runner.dart';

/// Silero VAD v5 runner.
///
/// Silero v5 is recurrent: each `detect` call carries over a 2×1×128 LSTM
/// hidden state tensor. We keep that state as a Dart-side [Float32List]
/// between frames and rebuild the input tensor each call.
///
/// Runs inference via `OrtSession.runAsync`, which internally maintains a
/// long-lived worker isolate — so FFI calls never touch the main isolate
/// (per IMPLEMENTATION_PLAN.md §2 "Gotchas").
class SileroVadRunner implements VadRunner {
  SileroVadRunner({required this.modelPath});

  final String modelPath;

  @override
  int get frameSize => 512;

  @override
  int get sampleRate => 16000;

  OrtSession? _session;
  OrtRunOptions? _runOptions;

  /// LSTM hidden state: shape [2, 1, 128] = 256 floats, zero-initialized.
  static const int _stateLen = 2 * 1 * 128;
  final Float32List _state = Float32List(_stateLen);

  bool _envInitialised = false;

  @override
  Future<Result<void, AppError>> load() async {
    try {
      if (!_envInitialised) {
        OrtEnv.instance.init();
        _envInitialised = true;
      }
      final file = File(modelPath);
      if (!file.existsSync()) {
        return Err<void, AppError>(
          ModelLoadError(modelPath, reason: 'file does not exist'),
        );
      }
      final opts = OrtSessionOptions();
      _session = OrtSession.fromFile(file, opts);
      _runOptions = OrtRunOptions();
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        ModelLoadError(
          modelPath,
          reason: 'failed to create OrtSession',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Future<Result<double, AppError>> detect(Float32List frame) async {
    final session = _session;
    final runOptions = _runOptions;
    if (session == null || runOptions == null) {
      return const Err<double, AppError>(
        ModelLoadError('silero', reason: 'detect called before load'),
      );
    }
    if (frame.length != frameSize) {
      return Err<double, AppError>(
        UnknownError(
          'frame length ${frame.length} != frameSize $frameSize',
        ),
      );
    }

    OrtValueTensor? inputTensor;
    OrtValueTensor? stateTensor;
    OrtValueTensor? srTensor;
    List<OrtValue?>? outputs;
    try {
      inputTensor = OrtValueTensor.createTensorWithDataList(
        frame,
        <int>[1, frameSize],
      );
      stateTensor = OrtValueTensor.createTensorWithDataList(
        _state,
        <int>[2, 1, 128],
      );
      srTensor = OrtValueTensor.createTensorWithData(sampleRate);

      outputs = await session.runAsync(runOptions, <String, OrtValue>{
        'input': inputTensor,
        'state': stateTensor,
        'sr': srTensor,
      });
      if (outputs == null || outputs.length < 2) {
        return const Err<double, AppError>(
          UnknownError('Silero VAD returned unexpected output shape'),
        );
      }
      final probValue = outputs[0]?.value;
      final prob = _extractScalar(probValue);
      if (prob == null) {
        return const Err<double, AppError>(
          UnknownError('Silero VAD output[0] is not a scalar float'),
        );
      }

      final newState = _extractFloats(outputs[1]?.value);
      if (newState != null && newState.length == _stateLen) {
        _state.setAll(0, newState);
      }

      return Ok<double, AppError>(prob);
    } on Object catch (e, st) {
      return Err<double, AppError>(
        UnknownError(
          'Silero VAD inference failed',
          cause: e,
          stackTrace: st,
        ),
      );
    } finally {
      inputTensor?.release();
      stateTensor?.release();
      srTensor?.release();
      if (outputs != null) {
        for (final v in outputs) {
          v?.release();
        }
      }
    }
  }

  @override
  Future<void> reset() async {
    for (var i = 0; i < _state.length; i++) {
      _state[i] = 0;
    }
  }

  @override
  Future<void> dispose() async {
    _session?.release();
    _session = null;
    _runOptions?.release();
    _runOptions = null;
  }

  /// Silero's probability output is shaped [1, 1]; different onnxruntime
  /// versions surface it as either `List<List<double>>` or a flat list or
  /// even a single double. Handle all three.
  static double? _extractScalar(Object? value) {
    if (value == null) return null;
    if (value is double) return value;
    if (value is num) return value.toDouble();
    if (value is List) {
      if (value.isEmpty) return null;
      final first = value.first;
      return _extractScalar(first);
    }
    return null;
  }

  static Float32List? _extractFloats(Object? value) {
    if (value == null) return null;
    if (value is Float32List) return value;
    if (value is List) {
      final flat = <double>[];
      void visit(Object? v) {
        if (v is num) {
          flat.add(v.toDouble());
        } else if (v is List) {
          for (final e in v) {
            visit(e);
          }
        }
      }

      visit(value);
      return Float32List.fromList(flat);
    }
    return null;
  }
}
