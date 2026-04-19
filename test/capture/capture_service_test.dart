import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/capture/capture_service.dart';
import 'package:voxsynth/capture/models/speech_segment.dart';
import 'package:voxsynth/core/errors.dart';
import 'package:voxsynth/core/result.dart';

/// 512 samples @ 16 kHz = 32 ms = 1024 bytes of s16le PCM.
const int _bytesPerFrame = 1024;

Uint8List _frame() => Uint8List(_bytesPerFrame);

class _FakePcmSource implements PcmSource {
  _FakePcmSource({this.permissionGranted = true});

  bool permissionGranted;
  final StreamController<Uint8List> _ctrl =
      StreamController<Uint8List>.broadcast();

  /// Push a PCM chunk as if it came from the mic.
  void push(Uint8List bytes) => _ctrl.add(bytes);

  /// Signal end-of-stream.
  Future<void> endOfStream() async {
    await _ctrl.close();
  }

  @override
  Future<Result<bool, AppError>> hasPermission() async =>
      Ok<bool, AppError>(permissionGranted);

  @override
  Future<Result<Stream<Uint8List>, AppError>> start() async =>
      Ok<Stream<Uint8List>, AppError>(_ctrl.stream);

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_ctrl.isClosed) await _ctrl.close();
  }
}

/// In-process VadProcessor: feeds PCM straight into a scripted segment list
/// and emits matching segments on the stream. Enough to exercise the
/// orchestration in MicCaptureService without an isolate.
class _ScriptedVadProcessor implements VadProcessor {
  _ScriptedVadProcessor({
    required this.scriptedSegments,
    this.framesPerSegment = 20,
  });

  /// Segments to emit, in order. The Nth segment fires after we've seen
  /// (N+1) * framesPerSegment frames.
  final List<SpeechSegment> scriptedSegments;
  final int framesPerSegment;

  final StreamController<SpeechSegment> _segCtrl =
      StreamController<SpeechSegment>.broadcast();
  final StreamController<AppError> _errCtrl =
      StreamController<AppError>.broadcast();

  int _framesSeen = 0;
  int _nextSegIdx = 0;
  bool _started = false;

  @override
  Future<Result<void, AppError>> start() async {
    _started = true;
    return const Ok<void, AppError>(null);
  }

  @override
  void feed(Uint8List pcm) {
    if (!_started) return;
    _framesSeen += pcm.length ~/ _bytesPerFrame;
    while (_nextSegIdx < scriptedSegments.length &&
        _framesSeen >= (_nextSegIdx + 1) * framesPerSegment) {
      _segCtrl.add(scriptedSegments[_nextSegIdx]);
      _nextSegIdx++;
    }
  }

  @override
  void flush() {}

  @override
  Stream<SpeechSegment> get segments => _segCtrl.stream;

  @override
  Stream<AppError> get errors => _errCtrl.stream;

  @override
  Future<void> stop() async {
    _started = false;
    if (!_segCtrl.isClosed) await _segCtrl.close();
    if (!_errCtrl.isClosed) await _errCtrl.close();
  }
}

class _FailingVadProcessor implements VadProcessor {
  final StreamController<SpeechSegment> _segCtrl =
      StreamController<SpeechSegment>.broadcast();
  final StreamController<AppError> _errCtrl =
      StreamController<AppError>.broadcast();

  @override
  Future<Result<void, AppError>> start() async =>
      const Err<void, AppError>(IsolateError('worker refused to start'));

  @override
  void feed(Uint8List pcm) {}

  @override
  void flush() {}

  @override
  Stream<SpeechSegment> get segments => _segCtrl.stream;

  @override
  Stream<AppError> get errors => _errCtrl.stream;

  @override
  Future<void> stop() async {
    if (!_segCtrl.isClosed) await _segCtrl.close();
    if (!_errCtrl.isClosed) await _errCtrl.close();
  }
}

class _FailingPcmSource implements PcmSource {
  @override
  Future<Result<bool, AppError>> hasPermission() async =>
      const Ok<bool, AppError>(true);

  @override
  Future<Result<Stream<Uint8List>, AppError>> start() async =>
      const Err<Stream<Uint8List>, AppError>(
        UnknownError('mic hardware busy'),
      );

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

Future<Directory> _tmpProvider() async {
  final d = await Directory.systemTemp.createTemp('voxsynth-cap-test-');
  return d;
}

void main() {
  group('MicCaptureService orchestration', () {
    test('rejects start when microphone permission is denied', () async {
      final pcm = _FakePcmSource(permissionGranted: false);
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-1',
      );

      final r = await svc.start();
      expect(r.isErr, isTrue);
      expect(r.errOrNull, isA<PermissionDeniedError>());

      await svc.dispose();
    });

    test('emits state transitions idle -> starting -> recording',
        () async {
      final pcm = _FakePcmSource();
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-2',
      );

      final seen = <CaptureState>[];
      final sub = svc.state.listen(seen.add);

      final r = await svc.start();
      expect(r.isOk, isTrue);
      // Drain microtasks.
      await Future<void>.delayed(Duration.zero);

      expect(seen, containsAllInOrder(<CaptureState>[
        CaptureState.starting,
        CaptureState.recording,
      ]));

      await sub.cancel();
      await svc.dispose();
    });

    test('forwards segments from the VAD processor to the public stream',
        () async {
      final sampleSegment = SpeechSegment(
        startMs: 0,
        endMs: 480,
        pcm16kMono: Uint8List.fromList(const <int>[1, 2, 3, 4]),
      );
      final pcm = _FakePcmSource();
      final vad = _ScriptedVadProcessor(
        scriptedSegments: <SpeechSegment>[sampleSegment],
        framesPerSegment: 10,
      );
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-3',
      );

      final received = <SpeechSegment>[];
      final sub = svc.segments.listen(received.add);

      await svc.start();
      // Feed 10 frames → should trigger one scripted segment.
      for (var i = 0; i < 10; i++) {
        pcm.push(_frame());
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(received, <SpeechSegment>[sampleSegment]);

      await sub.cancel();
      await svc.dispose();
    });

    test('stop finalizes a WAV file that matches the bytes fed', () async {
      final pcm = _FakePcmSource();
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-4',
        clock: () => DateTime.utc(2026, 4, 19, 10),
      );

      await svc.start();
      for (var i = 0; i < 5; i++) {
        pcm.push(_frame());
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final stopResult = await svc.stop();
      expect(stopResult.isOk, isTrue);
      final handle = stopResult.okOrNull!;
      expect(handle.id, 'test-4');
      expect(handle.audioFilePath, contains('recording-test-4.wav'));
      // 5 frames × 1024 bytes = 5120 bytes of PCM. At 16 kHz mono s16le
      // that's 5120 / (16000 * 2) * 1000 = 160 ms.
      expect(handle.durationMs, 160);

      final wav = File(handle.audioFilePath);
      expect(wav.existsSync(), isTrue);
      final bytes = await wav.readAsBytes();
      // 44-byte header + 5120 bytes of PCM.
      expect(bytes.length, 44 + 5120);
      // RIFF / WAVE magic.
      expect(bytes.sublist(0, 4), <int>[0x52, 0x49, 0x46, 0x46]);
      expect(bytes.sublist(8, 12), <int>[0x57, 0x41, 0x56, 0x45]);

      await svc.dispose();
    });

    test('stop before start returns an error', () async {
      final pcm = _FakePcmSource();
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-5',
      );

      final r = await svc.stop();
      expect(r.isErr, isTrue);

      await svc.dispose();
    });

    test('start twice without stop returns an error the second time',
        () async {
      final pcm = _FakePcmSource();
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-dup',
      );
      await svc.start();
      final second = await svc.start();
      expect(second.isErr, isTrue);
      await svc.dispose();
    });

    test('pause before start returns an error', () async {
      final pcm = _FakePcmSource();
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-pause-idle',
      );
      final r = await svc.pause();
      expect(r.isErr, isTrue);
      await svc.dispose();
    });

    test('propagates a VAD start failure and enters error state', () async {
      final pcm = _FakePcmSource();
      final vad = _FailingVadProcessor();
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-vad-fail',
      );
      final seen = <CaptureState>[];
      final sub = svc.state.listen(seen.add);
      final r = await svc.start();
      expect(r.isErr, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(seen, contains(CaptureState.error));
      await sub.cancel();
      await svc.dispose();
    });

    test('propagates a mic start failure and enters error state', () async {
      final pcm = _FailingPcmSource();
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-mic-fail',
      );
      final r = await svc.start();
      expect(r.isErr, isTrue);
      await svc.dispose();
    });

    test('pause transitions state and can be followed by stop', () async {
      final pcm = _FakePcmSource();
      final vad = _ScriptedVadProcessor(scriptedSegments: const []);
      final svc = MicCaptureService(
        pcmSource: pcm,
        vadProcessor: vad,
        tempDirProvider: _tmpProvider,
        idGenerator: () => 'test-6',
      );

      await svc.start();
      pcm.push(_frame());
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final pauseResult = await svc.pause();
      expect(pauseResult.isOk, isTrue);

      final stopResult = await svc.stop();
      expect(stopResult.isOk, isTrue);

      await svc.dispose();
    });
  });
}
