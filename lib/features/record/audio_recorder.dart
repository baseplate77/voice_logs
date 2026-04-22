import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart' as pkg;

import '../../core/app_error.dart';
import '../../core/result.dart';

/// Thin abstraction over a platform audio recorder so tests can mock it.
///
/// Implementations capture 16 kHz mono PCM (the rate expected by the
/// Parakeet bundle) and return the final recording as both an on-disk
/// wav path and a raw byte buffer.
abstract class AudioRecorder {
  /// Returns `true` if the OS has granted microphone permission.
  Future<bool> hasPermission();

  /// Begin recording to [destinationPath].
  Future<Result<void, CaptureError>> start({required String destinationPath});

  /// Stop the active recording.
  Future<Result<RecordedClip, CaptureError>> stop();

  /// Release any platform resources held by this recorder.
  Future<void> dispose();
}

/// Final recording handed back by [AudioRecorder.stop].
class RecordedClip {
  const RecordedClip({
    required this.wavBytes,
    required this.audioPath,
    required this.durationMs,
  });

  /// Raw wav bytes — includes the RIFF header; PCM16 little-endian body.
  final Uint8List wavBytes;

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
  DateTime? _startedAt;
  String? _activePath;

  @override
  Future<bool> hasPermission() => _recorder.hasPermission();

  @override
  Future<Result<void, CaptureError>> start({
    required String destinationPath,
  }) async {
    if (_activePath != null) {
      return const Err(RecorderStateError('Recorder already running.'));
    }
    if (!await _recorder.hasPermission()) {
      return const Err(PermissionDenied());
    }
    try {
      await _recorder.start(
        const pkg.RecordConfig(
          encoder: pkg.AudioEncoder.wav,
          sampleRate: 16000,
          numChannels: 1,
          bitRate: 256000,
        ),
        path: destinationPath,
      );
      _activePath = destinationPath;
      _startedAt = DateTime.now();
      return const Ok(null);
    } on Object catch (e, s) {
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
      final bytes = await File(path).readAsBytes();
      final duration = DateTime.now().difference(startedAt).inMilliseconds;
      _activePath = null;
      _startedAt = null;
      return Ok(
        RecordedClip(wavBytes: bytes, audioPath: path, durationMs: duration),
      );
    } on Object catch (e, s) {
      _activePath = null;
      _startedAt = null;
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
    await _recorder.dispose();
  }
}
