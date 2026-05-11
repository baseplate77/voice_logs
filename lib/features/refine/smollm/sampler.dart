import 'dart:math' as math;
import 'dart:typed_data';

/// Sampling configuration for one decode step.
///
/// `temperature == 0` short-circuits to argmax (cheapest, deterministic);
/// otherwise temperature scales the logits and (optional) top-p
/// nucleus-truncates the sampling distribution.
class SamplerConfig {
  const SamplerConfig({this.temperature = 0.3, this.topP, this.seed});

  /// `0` → greedy; otherwise softmax(logits / T) before sampling.
  final double temperature;

  /// Nucleus threshold. `null` disables top-p truncation.
  final double? topP;

  /// Optional RNG seed for deterministic sampling in tests.
  final int? seed;
}

/// Sample one token id from a [vocabSize]-wide [logits] row.
///
/// Caller is responsible for slicing the last-token row out of the
/// `[batch, seq, vocab]` ONNX output; this function operates on a flat
/// `Float32List` of length `vocabSize`.
int sampleToken({
  required Float32List logits,
  required int vocabSize,
  required SamplerConfig config,
  math.Random? rng,
}) {
  if (logits.length < vocabSize) {
    throw ArgumentError(
      'logits row length ${logits.length} < vocabSize $vocabSize',
    );
  }

  if (config.temperature <= 0) return _argMax(logits, vocabSize);

  final probs = _softmax(logits, vocabSize, config.temperature);
  final random =
      rng ?? (config.seed != null ? math.Random(config.seed) : math.Random());

  final topP = config.topP;
  if (topP == null || topP >= 1.0) return _sampleCdf(probs, random);

  return _sampleTopP(probs, topP, random);
}

int _argMax(Float32List logits, int vocabSize) {
  var bestIdx = 0;
  var bestVal = logits[0];
  for (var i = 1; i < vocabSize; i++) {
    if (logits[i] > bestVal) {
      bestVal = logits[i];
      bestIdx = i;
    }
  }
  return bestIdx;
}

Float32List _softmax(Float32List logits, int vocabSize, double temperature) {
  final scaled = Float32List(vocabSize);
  var maxVal = logits[0];
  for (var i = 1; i < vocabSize; i++) {
    if (logits[i] > maxVal) maxVal = logits[i];
  }
  var sum = 0.0;
  for (var i = 0; i < vocabSize; i++) {
    final v = math.exp((logits[i] - maxVal) / temperature);
    scaled[i] = v;
    sum += v;
  }
  for (var i = 0; i < vocabSize; i++) {
    scaled[i] = scaled[i] / sum;
  }
  return scaled;
}

int _sampleCdf(Float32List probs, math.Random rng) {
  final u = rng.nextDouble();
  var acc = 0.0;
  for (var i = 0; i < probs.length; i++) {
    acc += probs[i];
    if (u < acc) return i;
  }
  return probs.length - 1;
}

int _sampleTopP(Float32List probs, double topP, math.Random rng) {
  final indices = List<int>.generate(probs.length, (i) => i);
  indices.sort((a, b) => probs[b].compareTo(probs[a]));

  var cumulative = 0.0;
  var cutoff = indices.length;
  for (var i = 0; i < indices.length; i++) {
    cumulative += probs[indices[i]];
    if (cumulative >= topP) {
      cutoff = i + 1;
      break;
    }
  }
  final kept = indices.sublist(0, cutoff);

  // Re-normalize the truncated tail to sum to 1.
  var keptSum = 0.0;
  for (final i in kept) {
    keptSum += probs[i];
  }
  final u = rng.nextDouble() * keptSum;
  var acc = 0.0;
  for (final i in kept) {
    acc += probs[i];
    if (u < acc) return i;
  }
  return kept.last;
}
