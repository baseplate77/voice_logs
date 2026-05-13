import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:record/record.dart' as pkg;

import '../../core/app_error.dart';
import '../../core/result.dart';
import 'wav_io.dart';

/// Thin abstraction over a platform audio recorder so tests can mock it.
///
/// Implementations capture 16 kHz mono PCM and expose the same PCM stream
/// for live ASR while also writing a private wav file on stop.
abstract class AudioRecorder {
  /// Returns `true` if the OS has granted microphone permission.
  Future<bool> hasPermission();

  /// Live little-endian signed PCM16 mono chunks at 16 kHz.
  Stream<Uint8List> get pcm16Stream;

  /// Begin recording to [destinationPath].
  Future<Result<void, CaptureError>> start({required String destinationPath});

  /// Stop the active recording.
  Future<Result<RecordedClip, CaptureError>> stop();

  /// Release any platform resources held by this recorder.
  Future<void> dispose();
}

/// Final recording handed back by [AudioRecorder.stop].
class RecordedClip {
  const RecordedClip({required this.audioPath, required this.durationMs});

  /// Path to the wav file on disk.
  final String audioPath;

  /// Duration of the recording in milliseconds.
  final int durationMs;
}

/// Errors surfaced across the capture layer boundary.
sealed class CaptureError extends AppError {
  const CaptureError({required super.message, super.cause, super.stack});
}

/// The OS denied microphone permission.
final class PermissionDenied extends CaptureError {
  const PermissionDenied()
    : super(message: 'Microphone permission was denied.');
}

/// The recorder was in the wrong state for the requested operation.
final class RecorderStateError extends CaptureError {
  const RecorderStateError(String what) : super(message: what);
}

/// Generic platform failure from the underlying recorder plugin.
final class RecorderPlatformError extends CaptureError {
  const RecorderPlatformError({
    required super.message,
    super.cause,
    super.stack,
  });
}

/// `record`-package-backed recorder producing 16 kHz PCM16 mono wav.
class RecordPackageAudioRecorder implements AudioRecorder {
  RecordPackageAudioRecorder([pkg.AudioRecorder? recorder])
    : _recorder = recorder ?? pkg.AudioRecorder();

  final pkg.AudioRecorder _recorder;
  final _pcmController = StreamController<Uint8List>.broadcast();

  StreamSubscription<Uint8List>? _streamSub;
  IOSink? _wavSink;
  DateTime? _startedAt;
  String? _activePath;
  int _pcmByteCount = 0;
  static bool? _isSimulator;

  @override
  Stream<Uint8List> get pcm16Stream => _pcmController.stream;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  static Future<bool> _checkSimulator() async {
    if (_isSimulator != null) return _isSimulator!;
    try {
      const channel = MethodChannel('com.nj.voxsynth/runtime');
      _isSimulator =
          await channel.invokeMethod<bool>('isIosSimulator') ?? false;
    } on MissingPluginException {
      _isSimulator = false;
    }
    return _isSimulator!;
  }

  @override
  Future<Result<void, CaptureError>> start({
    required String destinationPath,
  }) async {
    if (_activePath != null) {
      return const Err(RecorderStateError('Recorder already running.'));
    }
    final sim = await _checkSimulator();
    if (!sim && !await _recorder.hasPermission()) {
      return const Err(PermissionDenied());
    }
    try {
      _pcmByteCount = 0;
      final file = File(destinationPath);
      file.parent.createSync(recursive: true);
      _wavSink = file.openWrite();
      _wavSink!.add(
        pcm16WavHeader(pcmDataBytes: 0, sampleRate: 16000, channels: 1),
      );

      final stream = await _recorder.startStream(
        const pkg.RecordConfig(
          encoder: pkg.AudioEncoder.pcm16bits,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
          streamBufferSize: 4096,
        ),
      );
      _streamSub = stream.listen((chunk) {
        _pcmByteCount += chunk.lengthInBytes;
        _wavSink?.add(chunk);
        if (!_pcmController.isClosed) {
          _pcmController.add(Uint8List.fromList(chunk));
        }
      }, onError: _pcmController.addError);
      _activePath = destinationPath;
      _startedAt = DateTime.now();
      return const Ok(null);
    } on Object catch (e, s) {
      await _streamSub?.cancel();
      _streamSub = null;
      await _wavSink?.close();
      _wavSink = null;
      _pcmByteCount = 0;
      try {
        File(destinationPath).deleteSync();
      } on Object {
        // Best-effort cleanup of a partial recording file.
      }
      return Err(
        RecorderPlatformError(
          message: 'Failed to start recording: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<Result<RecordedClip, CaptureError>> stop() async {
    final path = _activePath;
    final startedAt = _startedAt;
    if (path == null || startedAt == null) {
      return const Err(RecorderStateError('No active recording to stop.'));
    }
    try {
      await _recorder.stop();
      await _streamSub?.cancel();
      _streamSub = null;

      final duration = DateTime.now().difference(startedAt).inMilliseconds;
      await _wavSink?.flush();
      await _wavSink?.close();
      _wavSink = null;
      await patchPcm16WavHeader(
        path,
        pcmDataBytes: _pcmByteCount,
        sampleRate: 16000,
        channels: 1,
      );
      _activePath = null;
      _startedAt = null;
      _pcmByteCount = 0;
      return Ok(RecordedClip(audioPath: path, durationMs: duration));
    } on Object catch (e, s) {
      await _streamSub?.cancel();
      _streamSub = null;
      await _wavSink?.close();
      _wavSink = null;
      _activePath = null;
      _startedAt = null;
      _pcmByteCount = 0;
      return Err(
        RecorderPlatformError(
          message: 'Failed to stop recording: $e',
          cause: e,
          stack: s,
        ),
      );
    }
  }

  @override
  Future<void> dispose() async {
    await _streamSub?.cancel();
    await _wavSink?.close();
    await _pcmController.close();
    await _recorder.dispose();
  }
}
