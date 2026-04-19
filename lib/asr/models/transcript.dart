/// A single word with timing and confidence.
///
/// Parakeet-TDT emits per-token timings at model stride granularity (typically
/// 80 ms); words are assembled by joining subword pieces. [startMs]/[endMs]
/// are relative to the beginning of the audio clip handed to the runner,
/// *not* the enclosing recording.
final class Word {
  const Word({
    required this.text,
    required this.startMs,
    required this.endMs,
    required this.confidence,
  })  : assert(endMs >= startMs, 'endMs must be >= startMs'),
        assert(
          confidence >= 0.0 && confidence <= 1.0,
          'confidence must be in [0, 1]',
        );

  final String text;
  final int startMs;
  final int endMs;

  /// Model-reported confidence in [0, 1]. Parakeet-TDT doesn't produce
  /// strict probabilities; we normalize joiner logits/beam scores into this
  /// range on the Rust side.
  final double confidence;

  int get durationMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Word &&
          other.text == text &&
          other.startMs == startMs &&
          other.endMs == endMs &&
          other.confidence == confidence);

  @override
  int get hashCode => Object.hash(text, startMs, endMs, confidence);

  @override
  String toString() =>
      'Word("$text" $startMs..$endMs ms c=${confidence.toStringAsFixed(2)})';
}

/// A full transcript: the raw text, a word list with timings, and the
/// detected language (BCP-47 style, e.g. "en", "hi").
final class Transcript {
  const Transcript({
    required this.text,
    required this.words,
    required this.detectedLanguage,
  });

  final String text;
  final List<Word> words;

  /// BCP-47-ish language code detected by the runner. Parakeet-TDT-0.6B-v2
  /// is English-only and will always return "en". Future multilingual
  /// models can surface other codes.
  final String detectedLanguage;

  /// Empty transcript — returned when the runner sees silence.
  static const Transcript empty = Transcript(
    text: '',
    words: <Word>[],
    detectedLanguage: 'en',
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! Transcript) return false;
    if (other.text != text) return false;
    if (other.detectedLanguage != detectedLanguage) return false;
    if (other.words.length != words.length) return false;
    for (var i = 0; i < words.length; i++) {
      if (other.words[i] != words[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(text, detectedLanguage, Object.hashAll(words));

  @override
  String toString() =>
      'Transcript("$text", ${words.length} words, lang=$detectedLanguage)';
}
