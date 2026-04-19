// coverage:ignore-file
//
// VadWorkerIsolate spawns a real Isolate that loads Silero via native
// ONNX Runtime. It can't be instantiated inside `flutter test` because
// the worker's first action is SileroVadRunner.load(), which needs
// shared libs that the test harness does not bind. Orchestration logic
// around it is covered via IsolateVadProcessor swap-outs in
// capture_service_test.dart.

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';
import 'models/speech_segment.dart';
import 'silero_vad_runner.dart';
import 'vad_pipeline.dart';
import 'vad_segmenter.dart';

/// Spawns a dedicated isolate that runs a [VadPipeline] with Silero. PCM
/// chunks go in via SendPort; closed [SpeechSegment]s come back on
/// [segments].
///
/// The main isolate stays free to do UI work — only serialized PCM bytes
/// cross the isolate boundary.
class VadWorkerIsolate {
  VadWorkerIsolate({required this.sileroModelPath});

  final String sileroModelPath;

  Isolate? _isolate;
  SendPort? _sendPort;
  ReceivePort? _receivePort;
  StreamSubscription<Object?>? _sub;

  final StreamController<SpeechSegment> _segments =
      StreamController<SpeechSegment>.broadcast();
  final StreamController<AppError> _errors =
      StreamController<AppError>.broadcast();

  /// Closed speech segments emitted by the worker's segmenter.
  Stream<SpeechSegment> get segments => _segments.stream;

  /// Non-fatal errors from the worker (e.g. inference blips). Fatal errors
  /// come back as a completed [start] result.
  Stream<AppError> get errors => _errors.stream;

  /// Start the isolate and wait for it to load the Silero model.
  Future<Result<void, AppError>> start() async {
    if (_isolate != null) {
      return const Ok<void, AppError>(null);
    }
    final completer = Completer<Result<void, AppError>>();
    final rp = ReceivePort();
    _receivePort = rp;

    _sub = rp.listen((msg) {
      if (msg is SendPort) {
        _sendPort = msg;
        return;
      }
      if (msg is _LoadedMsg) {
        if (!completer.isCompleted) {
          completer.complete(const Ok<void, AppError>(null));
        }
        return;
      }
      if (msg is _LoadFailedMsg) {
        if (!completer.isCompleted) {
          completer.complete(Err<void, AppError>(msg.error));
        }
        return;
      }
      if (msg is _SegmentMsg) {
        _segments.add(msg.segment);
        return;
      }
      if (msg is _ErrorMsg) {
        _errors.add(msg.error);
        return;
      }
    });

    try {
      _isolate = await Isolate.spawn<_SpawnArgs>(
        _entry,
        _SpawnArgs(sendPort: rp.sendPort, modelPath: sileroModelPath),
        debugName: 'voxsynth-vad-worker',
      );
    } on Object catch (e, st) {
      await _teardown();
      return Err<void, AppError>(
        IsolateError(
          'failed to spawn VAD worker isolate',
          cause: e,
          stackTrace: st,
        ),
      );
    }

    return completer.future;
  }

  /// Send a PCM chunk to the worker. Returns immediately; segments arrive
  /// on [segments].
  void feed(Uint8List pcm) {
    final port = _sendPort;
    if (port == null) return;
    port.send(_FeedMsg(pcm: pcm));
  }

  /// Tell the worker to flush its in-flight segment (end-of-recording).
  void flush() {
    _sendPort?.send(const _FlushMsg());
  }

  /// Reset pipeline state for a new recording; keeps the model loaded.
  void reset() {
    _sendPort?.send(const _ResetMsg());
  }

  /// Stop and tear down the worker. Pending PCM is dropped.
  Future<void> stop() async {
    _sendPort?.send(const _StopMsg());
    await _teardown();
  }

  Future<void> _teardown() async {
    await _sub?.cancel();
    _sub = null;
    _receivePort?.close();
    _receivePort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
    if (!_segments.isClosed) await _segments.close();
    if (!_errors.isClosed) await _errors.close();
  }

  /// Isolate entry point. Runs a [VadPipeline] and relays messages.
  static Future<void> _entry(_SpawnArgs args) async {
    final rp = ReceivePort();
    args.sendPort.send(rp.sendPort);

    final pipeline = VadPipeline(
      runner: SileroVadRunner(modelPath: args.modelPath),
      segmenter: VadSegmenter(),
    );

    final loadResult = await pipeline.load();
    if (loadResult.isErr) {
      args.sendPort.send(_LoadFailedMsg(error: loadResult.errOrNull!));
      rp.close();
      return;
    }
    args.sendPort.send(const _LoadedMsg());

    await for (final msg in rp) {
      if (msg is _FeedMsg) {
        final r = await pipeline.feed(msg.pcm);
        r.fold((segs) {
          for (final s in segs) {
            args.sendPort.send(_SegmentMsg(segment: s));
          }
        }, (err) => args.sendPort.send(_ErrorMsg(error: err)));
      } else if (msg is _FlushMsg) {
        final tail = pipeline.flush();
        if (tail != null) {
          args.sendPort.send(_SegmentMsg(segment: tail));
        }
      } else if (msg is _ResetMsg) {
        await pipeline.reset();
      } else if (msg is _StopMsg) {
        await pipeline.dispose();
        rp.close();
        return;
      }
    }
  }
}

/// Isolate message types. Kept simple and top-level-serializable.
class _SpawnArgs {
  const _SpawnArgs({required this.sendPort, required this.modelPath});
  final SendPort sendPort;
  final String modelPath;
}

class _LoadedMsg {
  const _LoadedMsg();
}

class _LoadFailedMsg {
  const _LoadFailedMsg({required this.error});
  final AppError error;
}

class _FeedMsg {
  const _FeedMsg({required this.pcm});
  final Uint8List pcm;
}

class _FlushMsg {
  const _FlushMsg();
}

class _ResetMsg {
  const _ResetMsg();
}

class _StopMsg {
  const _StopMsg();
}

class _SegmentMsg {
  const _SegmentMsg({required this.segment});
  final SpeechSegment segment;
}

class _ErrorMsg {
  const _ErrorMsg({required this.error});
  final AppError error;
}
