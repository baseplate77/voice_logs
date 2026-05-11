import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

/// Layout of the merged-decoder ONNX export's KV cache.
///
/// SmolLM2-360M-Instruct (onnx-community export) follows HuggingFace
/// optimum's standard naming —
///   inputs  : `past_key_values.{i}.key`,  `past_key_values.{i}.value`
///   outputs : `present.{i}.key`,          `present.{i}.value`
/// — and uses grouped-query attention (5 KV heads × 64 dim) over 32
/// transformer layers.
///
/// Override only when pointing at a different model; the runner reads
/// these from a [KvCacheConfig] instance so it never hard-codes shapes.
class KvCacheConfig {
  const KvCacheConfig({
    required this.numLayers,
    required this.numKvHeads,
    required this.headDim,
  });

  /// Defaults verified against the onnx-community SmolLM2-360M-Instruct
  /// `config.json` (`num_hidden_layers`, `num_key_value_heads`,
  /// `hidden_size / num_attention_heads`).
  // ignore: constant_identifier_names — matches the upstream model name.
  static const KvCacheConfig smollm2_360m = KvCacheConfig(
    numLayers: 32,
    numKvHeads: 5,
    headDim: 64,
  );

  final int numLayers;
  final int numKvHeads;
  final int headDim;

  String pastKeyName(int layer) => 'past_key_values.$layer.key';
  String pastValueName(int layer) => 'past_key_values.$layer.value';
  String presentKeyName(int layer) => 'present.$layer.key';
  String presentValueName(int layer) => 'present.$layer.value';
}

/// Build an empty (`past_seq=0`) KV-cache input map for the prefill step.
///
/// `OrtValue.fromList` accepts a zero-length buffer when the shape's
/// product is zero; the merged-decoder export interprets that as "no
/// prior history" and runs the full attention over the new tokens.
Future<Map<String, OrtValue>> emptyKvInputs(
  KvCacheConfig cfg, {
  int batch = 1,
}) async {
  final shape = <int>[batch, cfg.numKvHeads, 0, cfg.headDim];
  final empty = Float32List(0);
  final out = <String, OrtValue>{};
  for (var i = 0; i < cfg.numLayers; i++) {
    out[cfg.pastKeyName(i)] = await OrtValue.fromList(empty, shape);
    out[cfg.pastValueName(i)] = await OrtValue.fromList(empty, shape);
  }
  return out;
}

/// Re-key the previous step's `present.*` outputs as the next step's
/// `past_key_values.*` inputs, disposing the now-stale `OrtValue`s the
/// caller hands ownership of via [stalePast].
///
/// The caller is responsible for disposing the returned map's values
/// when they're no longer needed (typically on the next call).
Future<Map<String, OrtValue>> rollKvCache({
  required KvCacheConfig cfg,
  required Map<String, OrtValue> stepOutputs,
  Map<String, OrtValue>? stalePast,
}) async {
  if (stalePast != null) {
    for (final v in stalePast.values) {
      await v.dispose();
    }
  }
  final next = <String, OrtValue>{};
  for (var i = 0; i < cfg.numLayers; i++) {
    final key = stepOutputs[cfg.presentKeyName(i)];
    final value = stepOutputs[cfg.presentValueName(i)];
    if (key == null || value == null) {
      throw StateError(
        'ONNX step did not return ${cfg.presentKeyName(i)} / '
        '${cfg.presentValueName(i)} — check the export I/O contract.',
      );
    }
    next[cfg.pastKeyName(i)] = key;
    next[cfg.pastValueName(i)] = value;
  }
  return next;
}

/// Dispose every `OrtValue` in [values]. Safe to call with a null/empty map.
Future<void> disposeOrtValues(Map<String, OrtValue>? values) async {
  if (values == null) return;
  for (final v in values.values) {
    await v.dispose();
  }
}
