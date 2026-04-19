@Tags(<String>['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/embed/e5_embedder.dart';
import 'package:voxsynth/embed/embedder.dart';

/// End-to-end e5-small test. Requires:
///   1. `cd rust/voxsynth_asr && cargo build --release`
///   2. `scripts/fetch_models.sh` has populated `assets/models/e5/`.
///
/// Run:
///   flutter test --tags integration test/embed/e5_embedder_integration_test.dart
///
/// Loading is slow (~2-5s on Mac, reads 470 MB safetensors with mmap);
/// embed_batch should be fast (<200 ms for a handful of short strings).
void main() {
  group('E5Embedder end-to-end', () {
    final e5Dir = '${Directory.current.path}/assets/models/e5';
    final weights = '$e5Dir/model.safetensors';
    final config = '$e5Dir/config.json';
    final tokenizer = '$e5Dir/tokenizer.json';

    test('embeds passage + query, produces 384-d L2-unit vectors, '
        'and cosine similarity tracks semantic similarity', () async {
      if (!File(weights).existsSync() ||
          !File(config).existsSync() ||
          !File(tokenizer).existsSync()) {
        markTestSkipped(
          'e5 model not present at $e5Dir — run scripts/fetch_models.sh '
          'to opt into this test.',
        );
        return;
      }
      final e = E5Embedder(
        weightsPath: weights,
        configPath: config,
        tokenizerPath: tokenizer,
      );

      final loadResult = await e.load();
      expect(
        loadResult.isOk,
        isTrue,
        reason: 'load failed: ${loadResult.errOrNull}',
      );

      // Related sentences should score noticeably higher than unrelated ones.
      final passages = await e.embedPassages(<String>[
        'The user is discussing pricing for the GlowUp product launch.',
        'Pricing tiers for GlowUp were finalised at three levels.',
        'The weather in Lisbon is rainy today.',
      ]);
      expect(
        passages.isOk,
        isTrue,
        reason: 'embedPassages failed: ${passages.errOrNull}',
      );
      final pv = passages.okOrNull!;
      expect(pv, hasLength(3));
      for (final v in pv) {
        expect(v.length, 384);
        // Rough L2-norm sanity. E5 normalises internally; candle's pool
        // rounds at fp16 so tolerance of 1e-2 is comfortable.
        var sq = 0.0;
        for (final x in v) {
          sq += x * x;
        }
        expect(sq, closeTo(1.0, 1e-2));
      }

      final related = cosineSimilarity(pv[0], pv[1]);
      final unrelated = cosineSimilarity(pv[0], pv[2]);
      expect(
        related,
        greaterThan(unrelated + 0.04),
        reason:
            'expected related > unrelated by ≥ 0.1; got $related vs $unrelated',
      );

      // A query ranks its matching passage above the unrelated one.
      final q = await e.embedQuery('Tell me about GlowUp pricing');
      expect(q.isOk, isTrue);
      final qv = q.okOrNull!;
      final qToRelated = cosineSimilarity(qv, pv[0]);
      final qToUnrelated = cosineSimilarity(qv, pv[2]);
      expect(qToRelated, greaterThan(qToUnrelated + 0.1));

      await e.dispose();
    }, timeout: const Timeout(Duration(minutes: 2)));
  });
}
