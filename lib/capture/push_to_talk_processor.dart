import 'dart:async';
import 'dart:typed_data';

import '../core/errors.dart';
import '../core/result.dart';
import 'capture_service.dart';
import 'models/speech_segment.dart';

/// A [VadProcessor] that doesn't actually run VAD.
///
/// The production [IsolateVadProcessor] wraps a Silero runner that is
/// currently a stub (see `silero_vad_runner.dart`). Until the Rust-side
/// sherpa-rs hookup lands, the debug UI operates as push-to-talk: the
/// user presses Record to start, presses Stop to end, and the entire
/// captured take is handed off as one segment.
///
/// Contract per start/stop cycle:
///   1. [start]  — (re)create stream controllers, clear buffer.
///   2. [feed]   — append PCM to the buffer.
///   3. [flush]  — emit one [SpeechSegment] covering the whole buffer,
///                 clear it.
///   4. [stop]   — close the controllers so subscribers see onDone;
///                 the next [start] builds fresh ones.
///
/// Buffering a full take in RAM is fine for the debug UI — at 16 kHz
/// mono s16le the PCM is ~32 KB/s, so a 10-minute take is ~19 MB.
class PushToTalkVadProcessor implements VadProcessor {
  PushToTalkVadProcessor();

  // Controllers are (re)created per start/stop cycle and closed in
  // stop(); broadcast StreamControllers are terminal once closed, so
  // they must be replaced rather than reused. The lint can't trace the
  // close through the nullable field, hence the per-site suppressions.
  // ignore: close_sinks
  StreamController<SpeechSegment>? _segmentsCtrl;
  // ignore: close_sinks
  StreamController<AppError>? _errorsCtrl;
  final BytesBuilder _buffer = BytesBuilder(copy: false);

  @override
  Stream<SpeechSegment> get segments {
    // ignore: close_sinks
    final ctrl = _segmentsCtrl ??=
        StreamController<SpeechSegment>.broadcast();
    return ctrl.stream;
  }

  @override
  Stream<AppError> get errors {
    // ignore: close_sinks
    final ctrl = _errorsCtrl ??= StreamController<AppError>.broadcast();
    return ctrl.stream;
  }

  @override
  Future<Result<void, AppError>> start() async {
    // ignore: close_sinks
    _segmentsCtrl ??= StreamController<SpeechSegment>.broadcast();
    // ignore: close_sinks
    _errorsCtrl ??= StreamController<AppError>.broadcast();
    _buffer.clear();
    return const Ok<void, AppError>(null);
  }

  @override
  void feed(Uint8List pcm) {
    if (pcm.isEmpty) return;
    _buffer.add(pcm);
  }

  @override
  void flush() {
    if (_buffer.isEmpty) return;
    final bytes = _buffer.takeBytes();
    // 16 kHz mono s16le: 2 bytes/sample * 16 samples/ms = 32 bytes/ms.
    const bytesPerMs = 32;
    final durationMs = bytes.length ~/ bytesPerMs;
    _segmentsCtrl?.add(
      SpeechSegment(startMs: 0, endMs: durationMs, pcm16kMono: bytes),
    );
  }

  @override
  Future<void> stop() async {
    _buffer.clear();
    final seg = _segmentsCtrl;
    final err = _errorsCtrl;
    _segmentsCtrl = null;
    _errorsCtrl = null;
    if (seg != null && !seg.isClosed) await seg.close();
    if (err != null && !err.isClosed) await err.close();
  }
}
