import 'dart:math' as math;
import 'dart:typed_data';

/// Pure functions for pooling and normalizing ONNX outputs. Split out so
/// unit tests never need a live model.

/// Apply mean pooling over [lastHiddenState] using [attentionMask].
///
/// [lastHiddenState] is a rank-3 tensor laid out as `[batch * seq *
/// hidden]` in row-major order with shape [batch, seq, hidden].
/// [attentionMask] is `[batch * seq]`, 1.0 where the token is real, 0.0
/// where it's a PAD. Returns `[batch * hidden]`.
Float32List meanPool({
  required Float32List lastHiddenState,
  required Float32List attentionMask,
  required int batch,
  required int seq,
  required int hidden,
}) {
  assert(
    lastHiddenState.length == batch * seq * hidden,
    'lastHiddenState shape does not match batch * seq * hidden',
  );
  assert(
    attentionMask.length == batch * seq,
    'attentionMask shape does not match batch * seq',
  );

  final out = Float32List(batch * hidden);
  for (var b = 0; b < batch; b++) {
    var sumMask = 0.0;
    for (var s = 0; s < seq; s++) {
      sumMask += attentionMask[b * seq + s];
    }
    if (sumMask == 0) continue; // leave zeros in out[b]

    for (var h = 0; h < hidden; h++) {
      var acc = 0.0;
      for (var s = 0; s < seq; s++) {
        final m = attentionMask[b * seq + s];
        if (m == 0) continue;
        acc += lastHiddenState[b * seq * hidden + s * hidden + h] * m;
      }
      out[b * hidden + h] = acc / sumMask;
    }
  }
  return out;
}

/// In-place L2 normalization over each of [batch] rows of length [hidden].
void l2Normalize({
  required Float32List values,
  required int batch,
  required int hidden,
}) {
  for (var b = 0; b < batch; b++) {
    var sqSum = 0.0;
    for (var h = 0; h < hidden; h++) {
      final v = values[b * hidden + h];
      sqSum += v * v;
    }
    final norm = math.sqrt(sqSum);
    if (norm == 0) continue;
    final inv = 1.0 / norm;
    for (var h = 0; h < hidden; h++) {
      values[b * hidden + h] = values[b * hidden + h] * inv;
    }
  }
}

/// True if every component is zero — produced when all tokens are padding.
bool isZeroVector(Float32List v) {
  for (var i = 0; i < v.length; i++) {
    if (v[i] != 0.0) return false;
  }
  return true;
}

/// Dot product. On L2-normalized vectors this is cosine similarity.
double cosineSimilarity(Float32List a, Float32List b) {
  assert(a.length == b.length, 'vector lengths must match');
  var acc = 0.0;
  for (var i = 0; i < a.length; i++) {
    acc += a[i] * b[i];
  }
  return acc;
}
