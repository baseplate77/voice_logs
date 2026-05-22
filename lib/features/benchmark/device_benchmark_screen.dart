import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:iconsax/iconsax.dart';
import 'package:path/path.dart' as p;

import '../../app_theme.dart';
import '../../core/result.dart';
import '../../core/worker/providers.dart';
import '../record/parakeet_runner.dart';
import '../record/recording_providers.dart';
import '../refine/llm_runner.dart';

// ---------------------------------------------------------------------------
// Benchmark prompt
// ---------------------------------------------------------------------------

const _benchmarkPrompt =
    'Write a short paragraph about how voice journaling helps with '
    'self-reflection and personal growth. Keep it under 80 words.';

const _testWavAsset = 'test_data/record_out_16k.wav';
const _testWavDurationSec = 59.94;

// ---------------------------------------------------------------------------
// Performance tiers
// ---------------------------------------------------------------------------

enum PerformanceTier {
  s('S', 'Superb', Color(0xFF6C3AED)),
  a('A', 'Great', Color(0xFF2563EB)),
  b('B', 'Good', Color(0xFF059669)),
  c('C', 'Usable', Color(0xFFD97706)),
  d('D', 'Slow', Color(0xFFDC2626));

  const PerformanceTier(this.label, this.name_, this.color);

  final String label;
  final String name_;
  final Color color;

  static PerformanceTier fromLlmTokensPerSec(double tps) {
    if (tps >= 25) return PerformanceTier.s;
    if (tps >= 15) return PerformanceTier.a;
    if (tps >= 8) return PerformanceTier.b;
    if (tps >= 3) return PerformanceTier.c;
    return PerformanceTier.d;
  }

  static PerformanceTier fromSttSpeedMultiplier(double x) {
    if (x >= 10) return PerformanceTier.s;
    if (x >= 7) return PerformanceTier.a;
    if (x >= 4) return PerformanceTier.b;
    if (x >= 2) return PerformanceTier.c;
    return PerformanceTier.d;
  }
}

// ---------------------------------------------------------------------------
// Result models
// ---------------------------------------------------------------------------

class LlmBenchmarkResult {
  const LlmBenchmarkResult({
    required this.loadTimeMs,
    required this.ttftMs,
    required this.totalGenTimeMs,
    required this.tokenCount,
    required this.tokensPerSec,
    required this.tier,
  });

  final int loadTimeMs;
  final int ttftMs;
  final int totalGenTimeMs;
  final int tokenCount;
  final double tokensPerSec;
  final PerformanceTier tier;
}

class SttBenchmarkResult {
  const SttBenchmarkResult({
    required this.bootstrapMs,
    required this.transcribeMs,
    required this.audioDurationSec,
    required this.speedMultiplier,
    required this.wordCount,
    required this.tier,
    required this.transcript,
  });

  final int bootstrapMs;
  final int transcribeMs;
  final double audioDurationSec;
  final double speedMultiplier;
  final int wordCount;
  final PerformanceTier tier;
  final String transcript;
}

// ---------------------------------------------------------------------------
// Phases
// ---------------------------------------------------------------------------

enum _Phase {
  idle,
  // LLM phases
  llmLoading,
  llmGenerating,
  // STT phases
  sttBootstrap,
  sttTranscribing,
  // Terminal
  done,
  error,
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class DeviceBenchmarkScreen extends ConsumerStatefulWidget {
  const DeviceBenchmarkScreen({super.key});

  @override
  ConsumerState<DeviceBenchmarkScreen> createState() =>
      _DeviceBenchmarkScreenState();
}

class _DeviceBenchmarkScreenState extends ConsumerState<DeviceBenchmarkScreen>
    with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.idle;
  LlmBenchmarkResult? _llmResult;
  SttBenchmarkResult? _sttResult;
  String _errorMessage = '';
  String _llmOutput = '';
  int _tokensSoFar = 0;

  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // LLM benchmark
  // -----------------------------------------------------------------------

  Future<bool> _runLlmBenchmark() async {
    setState(() {
      _phase = _Phase.llmLoading;
      _llmResult = null;
      _llmOutput = '';
      _tokensSoFar = 0;
    });

    final runner = ref.read(llmRunnerProvider);

    final loadWatch = Stopwatch()..start();
    final loadResult = await runner.load();
    final loadTimeMs = loadWatch.elapsedMilliseconds;

    switch (loadResult) {
      case Err(:final error):
        if (!mounted) return false;
        setState(() {
          _phase = _Phase.error;
          _errorMessage = 'LLM: ${error.message}';
        });
        return false;
      case Ok():
        break;
    }

    if (!mounted) return false;
    setState(() => _phase = _Phase.llmGenerating);

    final genWatch = Stopwatch()..start();
    int? ttftMs;
    var tokenCount = 0;
    LlmError? genError;

    if (runner is StreamingLlmRunner) {
      final stream = (runner as StreamingLlmRunner).generateStream(
        _benchmarkPrompt,
        temperature: 0.7,
        topK: 40,
      );
      await for (final chunk in stream) {
        switch (chunk) {
          case Ok(:final value):
            if (value.isNotEmpty) {
              ttftMs ??= genWatch.elapsedMilliseconds;
              tokenCount++;
              if (mounted) {
                setState(() {
                  _tokensSoFar = tokenCount;
                  _llmOutput += value;
                });
              }
            }
          case Err(:final error):
            genError = error;
        }
      }
    } else {
      final result = await runner.generate(
        _benchmarkPrompt,
        temperature: 0.7,
        topK: 40,
      );
      switch (result) {
        case Ok(:final value):
          ttftMs = genWatch.elapsedMilliseconds;
          tokenCount = (value.length / 4).ceil();
          if (mounted) setState(() => _llmOutput = value);
        case Err(:final error):
          genError = error;
      }
    }

    final totalGenTimeMs = genWatch.elapsedMilliseconds;
    if (!mounted) return false;

    if (genError != null || tokenCount == 0) {
      setState(() {
        _phase = _Phase.error;
        _errorMessage = genError?.message ?? 'No tokens generated';
      });
      return false;
    }

    final tokensPerSec =
        totalGenTimeMs > 0 ? (tokenCount / totalGenTimeMs) * 1000 : 0.0;

    setState(() {
      _llmResult = LlmBenchmarkResult(
        loadTimeMs: loadTimeMs,
        ttftMs: ttftMs ?? totalGenTimeMs,
        totalGenTimeMs: totalGenTimeMs,
        tokenCount: tokenCount,
        tokensPerSec: tokensPerSec,
        tier: PerformanceTier.fromLlmTokensPerSec(tokensPerSec),
      );
    });
    return true;
  }

  // -----------------------------------------------------------------------
  // STT benchmark
  // -----------------------------------------------------------------------

  Future<bool> _runSttBenchmark() async {
    if (!mounted) return false;
    setState(() {
      _phase = _Phase.sttBootstrap;
      _sttResult = null;
    });

    // Extract test WAV to a temp file
    final String tempWavPath;
    try {
      final data = await rootBundle.load(_testWavAsset);
      final tempDir = Directory.systemTemp;
      tempWavPath = p.join(tempDir.path, 'vox_bench_test.wav');
      await File(tempWavPath).writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    } on Object catch (e) {
      if (!mounted) return false;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = 'STT: Could not load test audio: $e';
      });
      return false;
    }

    // Bootstrap model files
    final bootstrap = ref.read(modelBootstrapProvider);
    final bootstrapWatch = Stopwatch()..start();
    final ParakeetModelPaths paths;
    try {
      paths = await bootstrap.ensureParakeet();
    } on Object catch (e) {
      if (!mounted) return false;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = 'STT: Model bootstrap failed: $e';
      });
      return false;
    }
    final bootstrapMs = bootstrapWatch.elapsedMilliseconds;

    if (!paths.allExist) {
      if (!mounted) return false;
      setState(() {
        _phase = _Phase.error;
        _errorMessage = 'STT: Parakeet model files not found on device';
      });
      return false;
    }

    if (!mounted) return false;
    setState(() => _phase = _Phase.sttTranscribing);

    // Transcribe in isolate (includes model load + decode)
    final runner = IsolateParakeetRunner(paths: paths);
    final transcribeWatch = Stopwatch()..start();
    final result = await runner.transcribeFileDetailed(tempWavPath);
    final transcribeMs = transcribeWatch.elapsedMilliseconds;

    // Clean up temp file
    try {
      await File(tempWavPath).delete();
    } on Object {
      // best effort
    }

    if (!mounted) return false;

    switch (result) {
      case Err(:final error):
        setState(() {
          _phase = _Phase.error;
          _errorMessage = 'STT: ${error.message}';
        });
        return false;
      case Ok(:final value):
        final fullText = value.segments.map((s) => s.text).join(' ');
        final wordCount =
            fullText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
        final speedMultiplier = transcribeMs > 0
            ? (_testWavDurationSec / (transcribeMs / 1000))
            : 0.0;

        setState(() {
          _sttResult = SttBenchmarkResult(
            bootstrapMs: bootstrapMs,
            transcribeMs: transcribeMs,
            audioDurationSec: _testWavDurationSec,
            speedMultiplier: speedMultiplier,
            wordCount: wordCount,
            tier: PerformanceTier.fromSttSpeedMultiplier(speedMultiplier),
            transcript: fullText,
          );
        });
        return true;
    }
  }

  // -----------------------------------------------------------------------
  // Run all
  // -----------------------------------------------------------------------

  Future<void> _runAll() async {
    setState(() {
      _llmResult = null;
      _sttResult = null;
      _errorMessage = '';
      _llmOutput = '';
    });

    final llmOk = await _runLlmBenchmark();
    if (!llmOk || !mounted) return;

    final sttOk = await _runSttBenchmark();
    if (!sttOk || !mounted) return;

    setState(() => _phase = _Phase.done);
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final isRunning = _phase != _Phase.idle &&
        _phase != _Phase.done &&
        _phase != _Phase.error;

    return Scaffold(
      backgroundColor: VoxAppColors.canvas,
      appBar: AppBar(
        title: Text(
          'DEVICE BENCHMARK',
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 14.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Model info cards
              const _ModelInfoCard(
                icon: Iconsax.cpu_setting,
                title: 'Gemma 3 1B IT',
                subtitle: 'Q4 LiteRT-LM  •  ~560 MB  •  Text generation',
              ),
              SizedBox(height: 10.h),
              const _ModelInfoCard(
                icon: Iconsax.microphone,
                title: 'Parakeet TDT 0.6B',
                subtitle: 'INT8 ONNX  •  ~630 MB  •  Transcription',
              ),
              SizedBox(height: 20.h),

              // Idle state
              if (_phase == _Phase.idle && _llmResult == null) ...[
                SizedBox(height: 24.h),
                Icon(Iconsax.cpu, size: 56.r, color: VoxAppColors.muted),
                SizedBox(height: 16.h),
                Text(
                  'Test how fast AI runs\non this device',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 15.sp,
                    color: VoxAppColors.muted,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: 6.h),
                Text(
                  'Benchmarks text generation and\nspeech transcription models',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: VoxAppColors.muted.withValues(alpha: 0.7),
                  ),
                ),
                SizedBox(height: 28.h),
              ],

              // Active phase indicator
              if (isRunning) ...[
                _PhaseCard(
                  icon: _phaseIcon,
                  title: _phaseTitle,
                  subtitle: _phaseSubtitle,
                  pulseController: _pulseController,
                ),
                SizedBox(height: 16.h),
              ],

              // Error
              if (_phase == _Phase.error) ...[
                SizedBox(height: 16.h),
                Icon(Iconsax.warning_2, size: 44.r, color: VoxAppColors.error),
                SizedBox(height: 10.h),
                Text(
                  'Benchmark Failed',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 15.sp,
                    fontWeight: FontWeight.w700,
                    color: VoxAppColors.error,
                  ),
                ),
                SizedBox(height: 6.h),
                Text(
                  _errorMessage,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.sp, color: VoxAppColors.muted),
                ),
                SizedBox(height: 20.h),
              ],

              // LLM Results
              if (_llmResult != null) ...[
                const _SectionHeader(icon: Iconsax.cpu_setting, title: 'LLM'),
                SizedBox(height: 10.h),
                _TierBadge(
                  tier: _llmResult!.tier,
                  metric: '${_llmResult!.tokensPerSec.toStringAsFixed(1)} tok/s',
                  subtitle: 'Text generation speed',
                ),
                SizedBox(height: 10.h),
                Row(
                  children: [
                    Expanded(
                      child: _MetricTile(
                        icon: Iconsax.timer_1,
                        label: 'LOAD',
                        value: _formatMs(_llmResult!.loadTimeMs),
                      ),
                    ),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: _MetricTile(
                        icon: Iconsax.flash_1,
                        label: 'FIRST TOKEN',
                        value: _formatMs(_llmResult!.ttftMs),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10.h),
                _LlmTierScale(activeTier: _llmResult!.tier),
                if (_llmOutput.isNotEmpty) ...[
                  SizedBox(height: 10.h),
                  _OutputCard(
                    title: 'LLM OUTPUT',
                    icon: Iconsax.message_text,
                    text: _llmOutput,
                  ),
                ],
                SizedBox(height: 20.h),
              ],

              // STT Results
              if (_sttResult != null) ...[
                const _SectionHeader(icon: Iconsax.microphone, title: 'STT'),
                SizedBox(height: 10.h),
                _TierBadge(
                  tier: _sttResult!.tier,
                  metric:
                      '${_sttResult!.speedMultiplier.toStringAsFixed(1)}x realtime',
                  subtitle: 'Transcription speed',
                ),
                SizedBox(height: 10.h),
                Row(
                  children: [
                    Expanded(
                      child: _MetricTile(
                        icon: Iconsax.timer_1,
                        label: 'TRANSCRIBE',
                        value: _formatMs(_sttResult!.transcribeMs),
                      ),
                    ),
                    SizedBox(width: 10.w),
                    Expanded(
                      child: _MetricTile(
                        icon: Iconsax.document_text,
                        label: 'WORDS',
                        value: '${_sttResult!.wordCount}',
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 10.h),
                _SttTierScale(activeTier: _sttResult!.tier),
                SizedBox(height: 10.h),
                _OutputCard(
                  title: 'TRANSCRIPT (${_sttResult!.audioDurationSec.toStringAsFixed(0)}s audio)',
                  icon: Iconsax.microphone,
                  text: _sttResult!.transcript,
                ),
                SizedBox(height: 20.h),
              ],

              // Run button
              _RunButton(
                onTap: isRunning ? null : _runAll,
                label: (_llmResult != null || _sttResult != null)
                    ? 'RUN AGAIN'
                    : 'RUN BENCHMARK',
              ),
              SizedBox(height: 24.h),
            ],
          ),
        ),
      ),
    );
  }

  IconData get _phaseIcon => switch (_phase) {
    _Phase.llmLoading => Iconsax.arrow_down,
    _Phase.llmGenerating => Iconsax.flash_1,
    _Phase.sttBootstrap => Iconsax.arrow_down,
    _Phase.sttTranscribing => Iconsax.microphone,
    _ => Iconsax.cpu,
  };

  String get _phaseTitle => switch (_phase) {
    _Phase.llmLoading => 'LOADING LLM',
    _Phase.llmGenerating => 'GENERATING',
    _Phase.sttBootstrap => 'PREPARING STT',
    _Phase.sttTranscribing => 'TRANSCRIBING',
    _ => '',
  };

  String get _phaseSubtitle => switch (_phase) {
    _Phase.llmLoading => 'Initializing Gemma 3 1B...',
    _Phase.llmGenerating => '$_tokensSoFar tokens so far...',
    _Phase.sttBootstrap => 'Extracting Parakeet model...',
    _Phase.sttTranscribing => 'Transcribing 60s test audio...',
    _ => '',
  };

  static String _formatMs(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16.r, color: VoxAppColors.accent),
        SizedBox(width: 6.w),
        Text(
          title,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 12.sp,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
            color: VoxAppColors.ink,
          ),
        ),
        SizedBox(width: 8.w),
        Expanded(child: Divider(color: VoxAppColors.outline, height: 1.h)),
      ],
    );
  }
}

class _ModelInfoCard extends StatelessWidget {
  const _ModelInfoCard({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: VoxAppColors.outline),
      ),
      child: Row(
        children: [
          Container(
            width: 38.w,
            height: 38.h,
            decoration: BoxDecoration(
              color: VoxAppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(10.r),
            ),
            child: Icon(icon, size: 18.r, color: VoxAppColors.ink),
          ),
          SizedBox(width: 12.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 2.h),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: VoxAppColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RunButton extends StatelessWidget {
  const _RunButton({required this.onTap, this.label = 'RUN BENCHMARK'});

  final VoidCallback? onTap;
  final String label;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 200),
        opacity: disabled ? 0.5 : 1.0,
        child: Container(
          height: 52.h,
          decoration: BoxDecoration(
            color: VoxAppColors.primary,
            borderRadius: BorderRadius.circular(12.r),
            boxShadow: disabled
                ? null
                : [
                    BoxShadow(
                      color: VoxAppColors.primary.withValues(alpha: 0.2),
                      blurRadius: 8.r,
                      offset: Offset(0.w, 4.h),
                    ),
                  ],
          ),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Iconsax.play, size: 18.r, color: Colors.white),
                SizedBox(width: 8.w),
                Text(
                  label,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PhaseCard extends StatelessWidget {
  const _PhaseCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.pulseController,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final AnimationController? pulseController;

  @override
  Widget build(BuildContext context) {
    Widget content = Container(
      padding: EdgeInsets.symmetric(horizontal: 16.w, vertical: 18.h),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14.r),
        border: Border.all(color: VoxAppColors.outline),
      ),
      child: Row(
        children: [
          Container(
            width: 42.w,
            height: 42.h,
            decoration: BoxDecoration(
              color: VoxAppColors.accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12.r),
            ),
            child: Icon(icon, size: 20.r, color: VoxAppColors.accent),
          ),
          SizedBox(width: 14.w),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.0,
                    color: VoxAppColors.ink,
                  ),
                ),
                SizedBox(height: 3.h),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12.sp,
                    color: VoxAppColors.muted,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 18.w,
            height: 18.h,
            child: CircularProgressIndicator(
              strokeWidth: 2.r,
              color: VoxAppColors.accent,
            ),
          ),
        ],
      ),
    );

    if (pulseController != null) {
      content = AnimatedBuilder(
        animation: pulseController!,
        builder: (context, child) {
          final opacity = 0.85 + 0.15 * pulseController!.value;
          return Opacity(opacity: opacity, child: child);
        },
        child: content,
      );
    }

    return content;
  }
}

class _TierBadge extends StatelessWidget {
  const _TierBadge({
    required this.tier,
    required this.metric,
    required this.subtitle,
  });

  final PerformanceTier tier;
  final String metric;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(vertical: 20.h),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16.r),
        border:
            Border.all(color: tier.color.withValues(alpha: 0.3), width: 1.5.w),
      ),
      child: Column(
        children: [
          Container(
            width: 64.w,
            height: 64.h,
            decoration: BoxDecoration(
              color: tier.color.withValues(alpha: 0.1),
              shape: BoxShape.circle,
              border: Border.all(
                color: tier.color.withValues(alpha: 0.3),
                width: 2.w,
              ),
            ),
            child: Center(
              child: Text(
                tier.label,
                style: TextStyle(
                  fontFamily: 'NDOT',
                  fontSize: 32.sp,
                  color: tier.color,
                ),
              ),
            ),
          ),
          SizedBox(height: 10.h),
          Text(
            'TIER ${tier.label} — ${tier.name_.toUpperCase()}',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 14.sp,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.0,
              color: tier.color,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            subtitle,
            style: TextStyle(
              fontSize: 12.sp,
              color: VoxAppColors.muted,
            ),
          ),
          SizedBox(height: 10.h),
          Text(
            metric,
            style: TextStyle(
              fontFamily: 'NDOT',
              fontSize: 26.sp,
              color: VoxAppColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: VoxAppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16.r, color: VoxAppColors.accent),
          SizedBox(height: 8.h),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: VoxAppColors.muted,
            ),
          ),
          SizedBox(height: 4.h),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 18.sp,
              fontWeight: FontWeight.w900,
              color: VoxAppColors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _LlmTierScale extends StatelessWidget {
  const _LlmTierScale({required this.activeTier});

  final PerformanceTier activeTier;

  @override
  Widget build(BuildContext context) {
    const ranges = {
      PerformanceTier.s: '25+ tok/s',
      PerformanceTier.a: '15-25 tok/s',
      PerformanceTier.b: '8-15 tok/s',
      PerformanceTier.c: '3-8 tok/s',
      PerformanceTier.d: '<3 tok/s',
    };
    return _TierScaleCard(
      title: 'LLM SCALE',
      activeTier: activeTier,
      ranges: ranges,
    );
  }
}

class _SttTierScale extends StatelessWidget {
  const _SttTierScale({required this.activeTier});

  final PerformanceTier activeTier;

  @override
  Widget build(BuildContext context) {
    const ranges = {
      PerformanceTier.s: '10x+ realtime',
      PerformanceTier.a: '7-10x realtime',
      PerformanceTier.b: '4-7x realtime',
      PerformanceTier.c: '2-4x realtime',
      PerformanceTier.d: '<2x realtime',
    };
    return _TierScaleCard(
      title: 'STT SCALE',
      activeTier: activeTier,
      ranges: ranges,
    );
  }
}

class _TierScaleCard extends StatelessWidget {
  const _TierScaleCard({
    required this.title,
    required this.activeTier,
    required this.ranges,
  });

  final String title;
  final PerformanceTier activeTier;
  final Map<PerformanceTier, String> ranges;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: VoxAppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12.sp,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: VoxAppColors.muted,
            ),
          ),
          SizedBox(height: 10.h),
          for (final tier in PerformanceTier.values) ...[
            _TierRow(
              tier: tier,
              isActive: tier == activeTier,
              range: ranges[tier] ?? '',
            ),
            if (tier != PerformanceTier.d) SizedBox(height: 5.h),
          ],
        ],
      ),
    );
  }
}

class _TierRow extends StatelessWidget {
  const _TierRow({
    required this.tier,
    required this.isActive,
    required this.range,
  });

  final PerformanceTier tier;
  final bool isActive;
  final String range;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 10.w, vertical: 7.h),
      decoration: BoxDecoration(
        color: isActive
            ? tier.color.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(8.r),
        border: isActive
            ? Border.all(color: tier.color.withValues(alpha: 0.25))
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 26.w,
            height: 26.h,
            decoration: BoxDecoration(
              color: isActive ? tier.color : tier.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6.r),
            ),
            child: Center(
              child: Text(
                tier.label,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12.sp,
                  fontWeight: FontWeight.w900,
                  color: isActive ? Colors.white : tier.color,
                ),
              ),
            ),
          ),
          SizedBox(width: 10.w),
          Expanded(
            child: Text(
              tier.name_,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12.sp,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: isActive ? VoxAppColors.ink : VoxAppColors.muted,
              ),
            ),
          ),
          Text(
            range,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12.sp,
              color: isActive ? tier.color : VoxAppColors.muted,
              fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          if (isActive) ...[
            SizedBox(width: 6.w),
            Icon(Iconsax.arrow_left_2, size: 12.r, color: tier.color),
          ],
        ],
      ),
    );
  }
}

class _OutputCard extends StatelessWidget {
  const _OutputCard({
    required this.title,
    required this.icon,
    required this.text,
  });

  final String title;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(14.r),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12.r),
        border: Border.all(color: VoxAppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14.r, color: VoxAppColors.accent),
              SizedBox(width: 6.w),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12.sp,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: VoxAppColors.muted,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: 10.h),
          SelectableText(
            text,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 12.sp,
              height: 1.5,
              color: VoxAppColors.ink.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }
}
