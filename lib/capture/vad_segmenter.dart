import 'dart:typed_data';

import 'models/speech_segment.dart';

/// Minimum continuous speech required to emit a segment. Short bursts
/// (coughs, door slams) below this are dropped. Per IMPLEMENTATION_PLAN §2.
const Duration kMinSpeechDuration = Duration(milliseconds: 300);

/// Minimum trailing silence required to close a speech segment. Shorter
/// pauses inside speech are bridged. Per IMPLEMENTATION_PLAN §2.
const Duration kMinSilenceDuration = Duration(milliseconds: 500);

/// Speech probability above which a frame is considered voiced.
///
/// Silero VAD's recommended threshold is 0.5; we expose it for tuning in
/// future phases but do not make it configurable at runtime.
const double kSpeechThreshold = 0.5;

/// Pure state machine that turns a stream of `(probability, frame_pcm)`
/// events into completed [SpeechSegment]s.
///
/// No isolates, no audio sources, no clocks — just logic. This keeps the
/// segmentation thresholds exhaustively testable without fixtures or a
/// real VAD model.
///
/// The segmenter tracks elapsed audio time by counting samples received,
/// *not* wall-clock time. That way late/delayed frames from the mic
/// pipeline don't inflate segment durations.
class VadSegmenter {
  VadSegmenter({
    this.minSpeechDuration = kMinSpeechDuration,
    this.minSilenceDuration = kMinSilenceDuration,
    this.speechThreshold = kSpeechThreshold,
    this.sampleRate = 16000,
    this.bytesPerSample = 2,
  });

  final Duration minSpeechDuration;
  final Duration minSilenceDuration;
  final double speechThreshold;
  final int sampleRate;
  final int bytesPerSample;

  /// Total samples consumed so far — single source of truth for timestamps.
  int _samplesSeen = 0;

  /// Index (ms from recording start) of the first voiced frame in the
  /// current candidate segment, or null if we're in silence.
  int? _candidateStartMs;

  /// PCM bytes accumulated since the candidate start. Stored as a list of
  /// Uint8List to avoid repeated concatenation; joined only when the
  /// segment is emitted.
  final List<Uint8List> _candidateBytes = <Uint8List>[];

  /// Running silence duration (ms) inside the current candidate segment.
  /// Silence shorter than [minSilenceDuration] is bridged (kept as part of
  /// the segment); silence longer closes the segment.
  int _silenceMs = 0;

  /// Samples of silence seen while inside a candidate segment — used to
  /// trim the trailing silence off when we emit.
  int _silenceTrailingSamples = 0;

  /// Feed one frame of audio. [probability] is the VAD speech probability
  /// for this frame; [framePcmBytes] is the raw s16le PCM of the same
  /// frame so we can attach it to the emitted segment verbatim.
  ///
  /// Returns a finished segment if this frame closed one, else null.
  SpeechSegment? feed({
    required double probability,
    required Uint8List framePcmBytes,
  }) {
    final frameSamples = framePcmBytes.length ~/ bytesPerSample;
    final frameStartMs = _msAtSamples(_samplesSeen);
    _samplesSeen += frameSamples;
    final frameEndMs = _msAtSamples(_samplesSeen);
    final frameDurationMs = frameEndMs - frameStartMs;

    final isSpeech = probability >= speechThreshold;

    if (_candidateStartMs == null) {
      // In silence — only transition to candidate on a voiced frame.
      if (isSpeech) {
        _candidateStartMs = frameStartMs;
        _candidateBytes.add(framePcmBytes);
        _silenceMs = 0;
        _silenceTrailingSamples = 0;
      }
      return null;
    }

    // Inside a candidate segment.
    _candidateBytes.add(framePcmBytes);

    if (isSpeech) {
      _silenceMs = 0;
      _silenceTrailingSamples = 0;
      return null;
    }

    _silenceMs += frameDurationMs;
    _silenceTrailingSamples += frameSamples;
    if (_silenceMs < minSilenceDuration.inMilliseconds) {
      // Brief pause — bridge it.
      return null;
    }

    // Silence is long enough: close the candidate.
    final segmentEndMs = frameEndMs - _silenceMs;
    final startMs = _candidateStartMs!;
    final durationMs = segmentEndMs - startMs;

    // Collect only the voiced portion's PCM (trim the trailing silence).
    final keptBytes = _concatBytes(
      _candidateBytes,
      trimTrailingBytes: _silenceTrailingSamples * bytesPerSample,
    );
    _candidateStartMs = null;
    _candidateBytes.clear();
    _silenceMs = 0;
    _silenceTrailingSamples = 0;

    if (durationMs < minSpeechDuration.inMilliseconds) {
      // Too short — drop without emitting.
      return null;
    }

    return SpeechSegment(
      startMs: startMs,
      endMs: segmentEndMs,
      pcm16kMono: keptBytes,
    );
  }

  /// Flush any in-flight candidate segment (for end-of-recording).
  /// Returns the segment if it meets the minimum speech duration, else null.
  SpeechSegment? flush() {
    if (_candidateStartMs == null) return null;

    final endMs = _msAtSamples(_samplesSeen) - _silenceMs;
    final startMs = _candidateStartMs!;
    final durationMs = endMs - startMs;
    final keptBytes = _concatBytes(
      _candidateBytes,
      trimTrailingBytes: _silenceTrailingSamples * bytesPerSample,
    );
    _candidateStartMs = null;
    _candidateBytes.clear();
    _silenceMs = 0;
    _silenceTrailingSamples = 0;

    if (durationMs < minSpeechDuration.inMilliseconds) return null;
    return SpeechSegment(startMs: startMs, endMs: endMs, pcm16kMono: keptBytes);
  }

  /// Clear all state. Call at the start of a fresh recording.
  void reset() {
    _samplesSeen = 0;
    _candidateStartMs = null;
    _candidateBytes.clear();
    _silenceMs = 0;
    _silenceTrailingSamples = 0;
  }

  int _msAtSamples(int samples) => (samples * 1000) ~/ sampleRate;

  static Uint8List _concatBytes(
    List<Uint8List> parts, {
    int trimTrailingBytes = 0,
  }) {
    final total =
        parts.fold<int>(0, (sum, p) => sum + p.length) - trimTrailingBytes;
    final out = Uint8List(total < 0 ? 0 : total);
    var offset = 0;
    var remaining = out.length;
    for (final p in parts) {
      if (remaining <= 0) break;
      final copy = p.length < remaining ? p.length : remaining;
      out.setRange(offset, offset + copy, p);
      offset += copy;
      remaining -= copy;
    }
    return out;
  }
}
