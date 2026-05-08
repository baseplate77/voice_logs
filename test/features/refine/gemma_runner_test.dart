import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/refine/gemma_runner.dart';

void main() {
  group('gemmaBackendLoadOrder', () {
    test('tries GPU before CPU when fallback is enabled', () {
      expect(
        gemmaBackendLoadOrder(
          preferredBackend: PreferredBackend.gpu,
          allowCpuFallback: true,
          isIosSimulator: false,
        ),
        const [PreferredBackend.gpu, PreferredBackend.cpu],
      );
    });

    test('does not add fallback when disabled', () {
      expect(
        gemmaBackendLoadOrder(
          preferredBackend: PreferredBackend.gpu,
          allowCpuFallback: false,
          isIosSimulator: false,
        ),
        const [PreferredBackend.gpu],
      );
    });

    test('keeps CPU-only configuration unchanged', () {
      expect(
        gemmaBackendLoadOrder(
          preferredBackend: PreferredBackend.cpu,
          allowCpuFallback: true,
          isIosSimulator: false,
        ),
        const [PreferredBackend.cpu],
      );
    });

    test('uses CPU directly on iOS Simulator', () {
      expect(
        gemmaBackendLoadOrder(
          preferredBackend: PreferredBackend.gpu,
          allowCpuFallback: true,
          isIosSimulator: true,
        ),
        const [PreferredBackend.cpu],
      );
    });
  });

  group('isRecoverableGemmaGpuLoadFailure', () {
    test('matches iOS Metal LiteRT delegate failures', () {
      const error =
          'PlatformException(failedToInitializeEngine, '
          'Calculator::Open() for node "odml.infra.LiteRTResourceCalculator" '
          'failed: RET_CHECK failure '
          'third_party/odml/infra/genai/inference/executor/'
          'llm_litert_metal_executor.mm:219 '
          'interpreter->ModifyGraphWithDelegate(gpu_delegate.get()) == '
          'kTfLiteOk)';

      expect(isRecoverableGemmaGpuLoadFailure(error), isTrue);
    });

    test('does not match unrelated model load failures', () {
      expect(isRecoverableGemmaGpuLoadFailure('model file not found'), isFalse);
    });
  });
}
