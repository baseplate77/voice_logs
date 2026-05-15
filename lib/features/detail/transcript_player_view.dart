import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/db/repositories/transcript_segment_repository.dart';
import 'audio_player_controller.dart';

/// Renders a transcript as tappable words. The currently-playing word
/// highlights as audio advances; tapping a word seeks audio to it. If the
/// caller passes a focused range (e.g. an Ask citation source span), the
/// matching words receive a sustained accent and the view auto-scrolls to
/// the first one on the next frame.
///
/// Falls back to a plain selectable text view when [segments] has no
/// word-level timings (older logs, or text-only recognizers).
class TranscriptPlayerView extends StatefulWidget {
  const TranscriptPlayerView({
    super.key,
    required this.segments,
    required this.controller,
    this.fallbackText = '',
    this.focusedStartMs,
    this.focusedEndMs,
  });

  /// Stored segments with optional per-word timings.
  final List<TranscriptSegmentView> segments;

  /// Audio controller whose position drives the highlight.
  final AudioPlayerController controller;

  /// Plain transcript text shown when no word timings exist. Usually the
  /// log's cleaned or raw transcript.
  final String fallbackText;

  /// Inclusive start of a source-span highlight in ms. Words whose start
  /// falls within `[focusedStartMs, focusedEndMs]` receive a sustained
  /// accent and the view scrolls to the first one.
  final int? focusedStartMs;

  /// Inclusive end of the focused span.
  final int? focusedEndMs;

  @override
  State<TranscriptPlayerView> createState() => _TranscriptPlayerViewState();
}

class _TranscriptPlayerViewState extends State<TranscriptPlayerView> {
  late final List<_FlatWord> _words;
  late final List<GlobalKey> _wordKeys;
  StreamSubscription<Duration>? _posSub;
  int? _activeIndex;
  bool _autoScrolled = false;

  @override
  void initState() {
    super.initState();
    _words = _flatten(widget.segments);
    _wordKeys = List.generate(_words.length, (_) => GlobalKey());
    if (_words.isNotEmpty) {
      _posSub = widget.controller.positionStream.listen(_onPosition);
    }
    if (_firstFocusedIndex() != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureFocusVisible(),
      );
    }
  }

  @override
  void didUpdateWidget(covariant TranscriptPlayerView old) {
    super.didUpdateWidget(old);
    final newFocus = _firstFocusedIndex();
    if (newFocus != null &&
        (old.focusedStartMs != widget.focusedStartMs ||
            old.focusedEndMs != widget.focusedEndMs)) {
      _autoScrolled = false;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _ensureFocusVisible(),
      );
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    super.dispose();
  }

  void _onPosition(Duration position) {
    final ms = position.inMilliseconds;
    final idx = _findActiveIndex(ms);
    if (idx != _activeIndex && mounted) {
      setState(() => _activeIndex = idx);
    }
  }

  int? _findActiveIndex(int positionMs) {
    if (_words.isEmpty) return null;
    for (var i = 0; i < _words.length; i++) {
      final w = _words[i];
      if (positionMs >= w.startMs && positionMs < w.endMs) return i;
    }
    final last = _words.last;
    if (positionMs >= last.startMs) return _words.length - 1;
    return null;
  }

  bool _isFocused(_FlatWord word) {
    final from = widget.focusedStartMs;
    final to = widget.focusedEndMs;
    if (from == null || to == null) return false;
    return word.startMs >= from && word.startMs <= to;
  }

  int? _firstFocusedIndex() {
    if (widget.focusedStartMs == null || widget.focusedEndMs == null) {
      return null;
    }
    for (var i = 0; i < _words.length; i++) {
      if (_isFocused(_words[i])) return i;
    }
    return null;
  }

  void _ensureFocusVisible() {
    if (_autoScrolled) return;
    final idx = _firstFocusedIndex();
    if (idx == null) return;
    final ctx = _wordKeys[idx].currentContext;
    if (ctx == null) return;
    Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 320),
      alignment: 0.2,
      curve: Curves.easeOutCubic,
    );
    _autoScrolled = true;
  }

  Future<void> _seekTo(int index) async {
    final w = _words[index];
    await widget.controller.seek(Duration(milliseconds: w.startMs));
    await widget.controller.play();
  }

  @override
  Widget build(BuildContext context) {
    if (_words.isEmpty) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(widget.fallbackText),
      );
    }
    final base = DefaultTextStyle.of(context).style;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (var i = 0; i < _words.length; i++)
            _WordChip(
              key: _wordKeys[i],
              word: _words[i].word,
              isActive: i == _activeIndex,
              isFocused: _isFocused(_words[i]),
              baseStyle: base,
              onTap: () => _seekTo(i),
            ),
        ],
      ),
    );
  }
}

class _WordChip extends StatelessWidget {
  const _WordChip({
    super.key,
    required this.word,
    required this.isActive,
    required this.isFocused,
    required this.baseStyle,
    required this.onTap,
  });

  final String word;
  final bool isActive;
  final bool isFocused;
  final TextStyle baseStyle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    Color? background;
    FontWeight? weight;
    if (isActive) {
      background = const Color(0xFFEFEAE0); // active (playhead) cream
      weight = FontWeight.w600;
    } else if (isFocused) {
      background = const Color(0xFFFFE5E2); // sustained source-span accent
      weight = FontWeight.w500;
    }
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
        decoration: background == null
            ? null
            : BoxDecoration(
                color: background,
                borderRadius: BorderRadius.circular(4),
              ),
        child: Text(word, style: baseStyle.copyWith(fontWeight: weight)),
      ),
    );
  }
}

class _FlatWord {
  const _FlatWord({
    required this.word,
    required this.startMs,
    required this.endMs,
  });
  final String word;
  final int startMs;
  final int endMs;
}

List<_FlatWord> _flatten(List<TranscriptSegmentView> segments) {
  final out = <_FlatWord>[];
  for (final seg in segments) {
    for (final w in seg.words) {
      if (w.word.isEmpty) continue;
      out.add(_FlatWord(word: w.word, startMs: w.startMs, endMs: w.endMs));
    }
  }
  return out;
}
