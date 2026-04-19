import 'dart:typed_data';

/// A contiguous block of detected speech carved out of a recording.
///
/// Timestamps are milliseconds from the start of the *enclosing recording*,
/// not from the start of the app session. PCM is 16 kHz, mono, signed
/// little-endian 16-bit — the canonical format Whisper expects in Phase 2.
final class SpeechSegment {
  const SpeechSegment({
    required this.startMs,
    required this.endMs,
    required this.pcm16kMono,
  }) : assert(endMs >= startMs, 'endMs must be >= startMs');

  /// Inclusive start, in milliseconds from the start of the recording.
  final int startMs;

  /// Exclusive end, in milliseconds from the start of the recording.
  final int endMs;

  /// Raw PCM: 16 kHz, mono, s16le.
  /// Length in bytes == `(endMs - startMs) * 32` (2 bytes × 16 samples/ms).
  final Uint8List pcm16kMono;

  /// Segment length in milliseconds.
  int get durationMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SpeechSegment &&
          other.startMs == startMs &&
          other.endMs == endMs &&
          _bytesEqual(other.pcm16kMono, pcm16kMono));

  @override
  int get hashCode => Object.hash(startMs, endMs, pcm16kMono.length);

  @override
  String toString() =>
      'SpeechSegment($startMs..$endMs ms, ${pcm16kMono.length} bytes)';

  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Lifecycle states of a [CaptureService].
enum CaptureState {
  /// Not recording. The default state.
  idle,

  /// Permission granted, audio source opening, isolate warming up.
  starting,

  /// Actively receiving mic frames; VAD is running.
  recording,

  /// Mic paused by the user; buffers retained, VAD quiesced.
  paused,

  /// Finalizing: flushing buffers, writing WAV, tearing down isolate.
  stopping,

  /// Unrecoverable failure. See the emitted [AppError] for details.
  error,
}

/// Opaque handle to a completed recording — the full audio file on disk plus
/// the metadata the rest of the app needs to find it.
///
/// Produced by [CaptureService.stop]; consumed by Phase 2 (ASR).
final class RecordingHandle {
  const RecordingHandle({
    required this.id,
    required this.audioFilePath,
    required this.durationMs,
    required this.startedAt,
  });

  /// Globally unique id (UUID or time-based). Same value appears as the
  /// `voice_logs.id` FK in the Phase 4 schema.
  final String id;

  /// Absolute path to the WAV file (s16le, 16 kHz, mono) on local disk.
  final String audioFilePath;

  /// Total recording length in milliseconds.
  final int durationMs;

  /// Wall-clock time when recording began.
  final DateTime startedAt;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is RecordingHandle &&
          other.id == id &&
          other.audioFilePath == audioFilePath &&
          other.durationMs == durationMs &&
          other.startedAt == startedAt);

  @override
  int get hashCode => Object.hash(id, audioFilePath, durationMs, startedAt);

  @override
  String toString() =>
      'RecordingHandle(id=$id, path=$audioFilePath, $durationMs ms)';
}
