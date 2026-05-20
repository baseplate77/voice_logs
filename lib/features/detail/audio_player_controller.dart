import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/logger.dart';

/// Lightweight wrapper around [AudioPlayer] for the detail screen. Keeps
/// the just_audio import contained to this file and exposes only the bits
/// the transcript view needs: load, play/pause, seek, and a position
/// stream that the transcript widget binds to.
class AudioPlayerController {
  AudioPlayerController() : _player = AudioPlayer();

  final AudioPlayer _player;
  final _log = Logger('audio_player');
  bool _disposed = false;

  /// Current playback position. Emits at the just_audio default cadence
  /// (~200ms) plus whenever a seek lands.
  Stream<Duration> get positionStream => _player.positionStream;

  /// Whether audio is currently playing. Bind to this for the play/pause
  /// button state.
  Stream<bool> get playingStream => _player.playingStream;

  /// Total clip duration once the source is loaded.
  Duration? get duration => _player.duration;

  /// Load a WAV file from disk. Returns null on success, an error message
  /// otherwise — caller is responsible for surfacing it.
  Future<String?> loadFile(String absolutePath) async {
    if (_disposed) return 'Player disposed';
    if (!File(absolutePath).existsSync()) {
      return 'Audio file not found at $absolutePath';
    }
    try {
      await _player.setFilePath(absolutePath);
      return null;
    } on Object catch (e, s) {
      _log.w('just_audio setFilePath failed', error: e, stack: s);
      return 'Failed to load audio: $e';
    }
  }

  /// Start playback from the current position.
  Future<void> play() => _player.play();

  /// Pause playback, leaving the position untouched.
  Future<void> pause() => _player.pause();

  /// Seek to [position]. Clamped to the loaded clip duration by just_audio.
  Future<void> seek(Duration position) => _player.seek(position);

  /// Current volume, in the range [0.0, 1.0].
  double get volume => _player.volume;

  /// Adjust the playback volume, in the range [0.0, 1.0].
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  /// Release native resources. Idempotent.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _player.dispose();
  }

  @visibleForTesting
  AudioPlayer get rawPlayer => _player;
}
