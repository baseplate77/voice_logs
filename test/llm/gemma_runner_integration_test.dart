@Tags(<String>['integration'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/llm/gemma_runner.dart';

/// End-to-end Gemma 3 1B IT test. Requires:
///   1. `cd rust/voxsynth_asr && cargo build --release`
///   2. `scripts/fetch_models.sh` has populated `assets/models/gemma/`.
///
/// Run with:
///   flutter test --tags integration test/llm/gemma_runner_integration_test.dart
///
/// Loading + first-token latency for the Q4_K_M model is 10–30s on a
/// development Mac; the timeout below is generous.
void main() {
  group('GemmaRunner end-to-end', () {
    final gemmaDir = '${Directory.current.path}/assets/models/gemma';
    final modelPath = '$gemmaDir/gemma-3-1b-it-Q4_K_M.gguf';
    final tokenizerPath = '$gemmaDir/tokenizer.json';

    test('load + generateSync returns non-empty text', () async {
      if (!File(modelPath).existsSync() ||
          !File(tokenizerPath).existsSync()) {
        markTestSkipped(
          'Gemma model not present at $gemmaDir — run scripts/fetch_models.sh '
          'to opt into this test.',
        );
        return;
      }
      final runner = GemmaRunner(
        modelPath: modelPath,
        tokenizerPath: tokenizerPath,
      );

      final loadResult = await runner.load(maxTokens: 64, temperature: 0.0);
      expect(
        loadResult.isOk,
        isTrue,
        reason: 'load failed: ${loadResult.errOrNull}',
      );

      // Use a short, well-constrained prompt so the Q4 model produces
      // a predictable completion within 64 tokens.
      const prompt = 'The capital of France is';
      final genResult = await runner.generateSync(prompt);
      expect(
        genResult.isOk,
        isTrue,
        reason: 'generate failed: ${genResult.errOrNull}',
      );
      final text = genResult.okOrNull!.trim();
      expect(text, isNotEmpty);
      // Loose sanity check: Gemma 3 1B reliably completes this prompt
      // with "Paris" near the start of the generation.
      expect(
        text.toLowerCase().contains('paris'),
        isTrue,
        reason: 'expected "paris" in completion, got: "$text"',
      );

      await runner.dispose();
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
