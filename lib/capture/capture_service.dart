import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart' as rec;

import '../core/errors.dart';
import '../core/result.dart';
import 'models/speech_segment.dart';
import 'vad_pipeline.dart';
import 'vad_worker_isolate.dart';

/// Public capture facade.
///
/// Matches the interface in IMPLEMENTATION_PLAN.md §2 but wraps all async
/// operations in [Result] so errors don't throw across layers.
abstract class CaptureService {
  /// Begin a new recording: request permission, open the mic, spin up the
  /// VAD worker. [CaptureState.recording] is emitted once audio is flowing.
  Future<Result<void, AppError>> start();

  /// Pause the mic. VAD is quiesced but the isolate stays alive so [start]
  /// can resume cheaply. (Implementation note: Phase 1 maps pause to stop
  /// with resume-not-supported; proper pause/resume is Phase 2's ASR work.)
  Future<Result<void, AppError>> pause();

  /// Close the recording, finalize the WAV file on disk, tear down the
  /// worker, and return a [RecordingHandle].
  Future<Result<RecordingHandle, AppError>> stop();

  /// Emitted for every detected speech segment. Broadcast — multiple
  /// listeners are fine.
  Stream<SpeechSegment> get segments;

  /// Lifecycle transitions.
  Stream<CaptureState> get state;

  /// Release all resources permanently. Service must not be used after.
  Future<void> dispose();
}

/// Source of raw 16 kHz s16le PCM. Abstracted so tests can inject a fake
/// without touching the `record` package or real microphones.
abstract class PcmSource {
  Future<Result<bool, AppError>> hasPermission();
  Future<Result<Stream<Uint8List>, AppError>> start();
  Future<void> stop();
  Future<void> dispose();
}

/// VAD front-end. `VadWorkerIsolate` is the production implementation; a
/// test double can run a [VadPipeline] in-process.
abstract class VadProcessor {
  Future<Result<void, AppError>> start();
  void feed(Uint8List pcm);
  void flush();
  Stream<SpeechSegment> get segments;
  Stream<AppError> get errors;
  Future<void> stop();
}

/// Production [PcmSource] backed by `package:record`. Emits 16 kHz, mono,
/// signed-16-bit little-endian PCM.
class RecordPcmSource implements PcmSource {
  RecordPcmSource({rec.AudioRecorder? recorder})
      : _recorder = recorder ?? rec.AudioRecorder();

  final rec.AudioRecorder _recorder;

  @override
  Future<Result<bool, AppError>> hasPermission() async {
    try {
      final ok = await _recorder.hasPermission();
      return Ok<bool, AppError>(ok);
    } on Object catch (e, st) {
      return Err<bool, AppError>(
        PermissionDeniedError('microphone', cause: e, stackTrace: st),
      );
    }
  }

  @override
  Future<Result<Stream<Uint8List>, AppError>> start() async {
    try {
      final stream = await _recorder.startStream(
        const rec.RecordConfig(
          encoder: rec.AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
        ),
      );
      return Ok<Stream<Uint8List>, AppError>(stream);
    } on Object catch (e, st) {
      return Err<Stream<Uint8List>, AppError>(
        UnknownError(
          'failed to start audio stream',
          cause: e,
          stackTrace: st,
        ),
      );
    }
  }

  @override
  Future<void> stop() async {
    await _recorder.stop();
  }

  @override
  Future<void> dispose() async {
    await _recorder.dispose();
  }
}

/// Production [VadProcessor] backed by a [VadWorkerIsolate].
class IsolateVadProcessor implements VadProcessor {
  IsolateVadProcessor({required this.sileroModelPath})
      : _worker = VadWorkerIsolate(sileroModelPath: sileroModelPath);

  final String sileroModelPath;
  final VadWorkerIsolate _worker;

  @override
  Future<Result<void, AppError>> start() => _worker.start();

  @override
  void feed(Uint8List pcm) => _worker.feed(pcm);

  @override
  void flush() => _worker.flush();

  @override
  Stream<SpeechSegment> get segments => _worker.segments;

  @override
  Stream<AppError> get errors => _worker.errors;

  @override
  Future<void> stop() => _worker.stop();
}

/// Production [CaptureService]. Orchestrates permission → mic → VAD
/// worker → WAV file. Tests can construct one with fake dependencies.
class MicCaptureService implements CaptureService {
  MicCaptureService({
    required PcmSource pcmSource,
    required VadProcessor vadProcessor,
    Future<Directory> Function()? tempDirProvider,
    String Function()? idGenerator,
    DateTime Function()? clock,
  })  : _pcm = pcmSource,
        _vad = vadProcessor,
        _tempDir = tempDirProvider ?? getTemporaryDirectory,
        _genId = idGenerator ?? _defaultId,
        _now = clock ?? DateTime.now;

  final PcmSource _pcm;
  final VadProcessor _vad;
  final Future<Directory> Function() _tempDir;
  final String Function() _genId;
  final DateTime Function() _now;

  final StreamController<SpeechSegment> _segmentsCtrl =
      StreamController<SpeechSegment>.broadcast();
  final StreamController<CaptureState> _stateCtrl =
      StreamController<CaptureState>.broadcast();

  CaptureState _state = CaptureState.idle;
  StreamSubscription<Uint8List>? _pcmSub;
  StreamSubscription<SpeechSegment>? _segSub;
  StreamSubscription<AppError>? _errSub;

  IOSink? _wavSink;
  File? _wavFile;
  int _pcmBytesWritten = 0;
  DateTime? _recordingStartedAt;
  String? _recordingId;

  @override
  Stream<SpeechSegment> get segments => _segmentsCtrl.stream;

  @override
  Stream<CaptureState> get state => _stateCtrl.stream;

  @override
  Future<Result<void, AppError>> start() async {
    if (_state != CaptureState.idle) {
      return const Err<void, AppError>(
        UnknownError('capture already in progress'),
      );
    }
    _setState(CaptureState.starting);

    final permission = await _pcm.hasPermission();
    if (permission.isErr) {
      _setState(CaptureState.error);
      return Err<void, AppError>(permission.errOrNull!);
    }
    if (permission.okOrNull != true) {
      _setState(CaptureState.error);
      return const Err<void, AppError>(
        PermissionDeniedError('microphone'),
      );
    }

    final vadStart = await _vad.start();
    if (vadStart.isErr) {
      _setState(CaptureState.error);
      return vadStart;
    }

    // Open WAV file for archival. Write a 44-byte placeholder header;
    // finalize on stop() once we know the total PCM length.
    final dir = await _tempDir();
    final id = _genId();
    final file = File(p.join(dir.path, 'recording-$id.wav'));
    _wavFile = file;
    _wavSink = file.openWrite()..add(_wavHeaderPlaceholder());
    _pcmBytesWritten = 0;
    _recordingId = id;
    _recordingStartedAt = _now();

    final streamResult = await _pcm.start();
    if (streamResult.isErr) {
      await _closeWavOnError();
      await _vad.stop();
      _setState(CaptureState.error);
      return Err<void, AppError>(streamResult.errOrNull!);
    }

    _segSub = _vad.segments.listen(_segmentsCtrl.add);
    _errSub = _vad.errors.listen((_) {
      // Non-fatal VAD errors: log-level. Don't kill the recording.
    });
    _pcmSub = streamResult.okOrNull!.listen(
      (chunk) {
        _wavSink?.add(chunk);
        _pcmBytesWritten += chunk.length;
        _vad.feed(chunk);
      },
      onError: (Object e, StackTrace st) {
        _setState(CaptureState.error);
      },
    );

    _setState(CaptureState.recording);
    return const Ok<void, AppError>(null);
  }

  @override
  Future<Result<void, AppError>> pause() async {
    if (_state != CaptureState.recording) {
      return const Err<void, AppError>(
        UnknownError('pause called while not recording'),
      );
    }
    await _pcmSub?.cancel();
    _pcmSub = null;
    await _pcm.stop();
    _setState(CaptureState.paused);
    return const Ok<void, AppError>(null);
  }

  @override
  Future<Result<RecordingHandle, AppError>> stop() async {
    if (_state == CaptureState.idle) {
      return const Err<RecordingHandle, AppError>(
        UnknownError('stop called while idle'),
      );
    }
    _setState(CaptureState.stopping);

    await _pcmSub?.cancel();
    _pcmSub = null;
    await _pcm.stop();

    // Flush any in-flight segment from the VAD.
    _vad.flush();
    // Give the worker a brief moment to emit the flushed segment.
    await Future<void>.delayed(const Duration(milliseconds: 50));

    await _segSub?.cancel();
    _segSub = null;
    await _errSub?.cancel();
    _errSub = null;
    await _vad.stop();

    final file = _wavFile;
    final startedAt = _recordingStartedAt;
    final id = _recordingId;
    if (file == null || startedAt == null || id == null) {
      _setState(CaptureState.error);
      return const Err<RecordingHandle, AppError>(
        UnknownError('stop: recording state is inconsistent'),
      );
    }

    final result = await _finalizeWav(file, _pcmBytesWritten);
    if (result.isErr) {
      _setState(CaptureState.error);
      return Err<RecordingHandle, AppError>(result.errOrNull!);
    }

    final durationMs = _bytesToMs(_pcmBytesWritten);
    final handle = RecordingHandle(
      id: id,
      audioFilePath: file.path,
      durationMs: durationMs,
      startedAt: startedAt,
    );

    _wavSink = null;
    _wavFile = null;
    _pcmBytesWritten = 0;
    _recordingStartedAt = null;
    _recordingId = null;
    _setState(CaptureState.idle);
    return Ok<RecordingHandle, AppError>(handle);
  }

  @override
  Future<void> dispose() async {
    await _pcmSub?.cancel();
    await _segSub?.cancel();
    await _errSub?.cancel();
    await _closeWavOnError();
    await _pcm.dispose();
    await _vad.stop();
    if (!_segmentsCtrl.isClosed) await _segmentsCtrl.close();
    if (!_stateCtrl.isClosed) await _stateCtrl.close();
  }

  void _setState(CaptureState s) {
    _state = s;
    _stateCtrl.add(s);
  }

  Future<void> _closeWavOnError() async {
    try {
      await _wavSink?.close();
    } on Object catch (_) {
      // best-effort
    }
    _wavSink = null;
    _wavFile = null;
  }

  Future<Result<void, AppError>> _finalizeWav(File file, int pcmBytes) async {
    try {
      await _wavSink?.flush();
      await _wavSink?.close();
      _wavSink = null;

      // Rewrite the 44-byte header with the real sizes.
      final raf = await file.open(mode: FileMode.writeOnlyAppend);
      try {
        await raf.setPosition(0);
        await raf.writeFrom(_wavHeader(pcmBytes: pcmBytes));
      } finally {
        await raf.close();
      }
      return const Ok<void, AppError>(null);
    } on Object catch (e, st) {
      return Err<void, AppError>(
        StorageError('failed to finalize WAV file', cause: e, stackTrace: st),
      );
    }
  }

  static int _bytesToMs(int bytes) => (bytes * 1000) ~/ (16000 * 2);

  /// Placeholder WAV header — the data-size fields are filled in on stop().
  static Uint8List _wavHeaderPlaceholder() => _wavHeader(pcmBytes: 0);

  /// Build a 44-byte RIFF/WAVE header for 16 kHz mono s16le PCM of length
  /// [pcmBytes]. ByteData setters default to big-endian; multi-byte
  /// integer fields in WAVE are little-endian, so we pass Endian.little
  /// for those. The FourCC markers ("RIFF", "WAVE", "fmt ", "data") are
  /// byte literals — endianness doesn't matter for their bytes but we use
  /// big-endian setUint32 so the literal reads left-to-right.
  static Uint8List _wavHeader({required int pcmBytes}) {
    const sampleRate = 16000;
    const channels = 1;
    const bitsPerSample = 16;
    const byteRate = sampleRate * channels * (bitsPerSample ~/ 8);
    const blockAlign = channels * (bitsPerSample ~/ 8);

    final header = ByteData(44)
      ..setUint32(0, 0x52494646) // "RIFF"
      ..setUint32(4, 36 + pcmBytes, Endian.little)
      ..setUint32(8, 0x57415645) // "WAVE"
      ..setUint32(12, 0x666d7420) // "fmt "
      ..setUint32(16, 16, Endian.little) // fmt chunk size
      ..setUint16(20, 1, Endian.little) // PCM format
      ..setUint16(22, channels, Endian.little)
      ..setUint32(24, sampleRate, Endian.little)
      ..setUint32(28, byteRate, Endian.little)
      ..setUint16(32, blockAlign, Endian.little)
      ..setUint16(34, bitsPerSample, Endian.little)
      ..setUint32(36, 0x64617461) // "data"
      ..setUint32(40, pcmBytes, Endian.little);

    return header.buffer.asUint8List();
  }

  static String _defaultId() {
    final rng = math.Random();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final rnd = rng.nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return '${ts}_$rnd';
  }
}
