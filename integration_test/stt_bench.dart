// Run with:
//   flutter test integration_test/stt_bench.dart \
//     -d 28141JEGR14622 --profile
//
// Measures Parakeet (offline NEMO TDT 0.6B int8) full-clip transcription
// latency against test_data/record_out_16k.wav (~60s of speech) under
// three configs:
//   1. CPU, 2 threads  ← matches lib/features/record/parakeet_runner.dart
//   2. CPU, 4 threads
//   3. NNAPI, 4 threads (Android)
//
// Each config: cold load + 1 untimed warmup + 5 timed iterations.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import 'package:voxsynth/core/native_paths.dart';
import 'package:voxsynth/features/record/parakeet_runner.dart';

import '_bench/fixtures.dart';
import '_bench/runner.dart';

const _fixtureAsset = 'test_data/record_out_16k.wav';
const _fixtureSeconds = 59.94;

const _parakeetAssets = <String>[
  'assets/models/parakeet/encoder.int8.onnx',
  'assets/models/parakeet/decoder.int8.onnx',
  'assets/models/parakeet/joiner.int8.onnx',
  'assets/models/parakeet/tokens.txt',
];

/// Stages parakeet model files from the asset bundle to a writable
/// directory. Bypasses ModelBootstrap because that swallows copy errors
/// via Logger; here we want hard failures on the bench path.
Future<ParakeetModelPaths> _stageParakeet(String supportPath) async {
  final modelsDir = Directory(p.join(supportPath, 'models'));
  if (!modelsDir.existsSync()) modelsDir.createSync(recursive: true);

  for (final asset in _parakeetAssets) {
    final dest = p.join(supportPath, asset.replaceFirst('assets/', ''));
    await extractAsset(asset, dest);
    final exists = File(dest).existsSync();
    final size = exists ? File(dest).lengthSync() : 0;
    // ignore: avoid_print
    print('  staged: $asset → $dest  (exists=$exists, ${size}B)');
    if (!exists || size == 0) {
      throw StateError('Failed to stage $asset to $dest');
    }
  }

  return ParakeetModelPaths(
    encoder: p.join(supportPath, 'models/parakeet/encoder.int8.onnx'),
    decoder: p.join(supportPath, 'models/parakeet/decoder.int8.onnx'),
    joiner: p.join(supportPath, 'models/parakeet/joiner.int8.onnx'),
    tokens: p.join(supportPath, 'models/parakeet/tokens.txt'),
  );
}

Future<sherpa.OfflineRecognizer> _createRecognizer({
  required ParakeetModelPaths paths,
  required int numThreads,
  required String provider,
}) async {
  final config = sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      transducer: sherpa.OfflineTransducerModelConfig(
        encoder: paths.encoder,
        decoder: paths.decoder,
        joiner: paths.joiner,
      ),
      tokens: paths.tokens,
      modelType: 'nemo_transducer',
      numThreads: numThreads,
      provider: provider,
      debug: false,
    ),
  );
  return sherpa.OfflineRecognizer(config);
}

Future<({String text, int us})> _transcribeOnce(
  sherpa.OfflineRecognizer recognizer,
  String wavPath,
) async {
  final wave = sherpa.readWave(wavPath);
  final sw = Stopwatch()..start();
  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: wave.samples, sampleRate: wave.sampleRate);
  recognizer.decode(stream);
  final result = recognizer.getResult(stream);
  stream.free();
  sw.stop();
  return (text: result.text, us: sw.elapsedMicroseconds);
}

Future<BenchResult> _benchConfig({
  required String name,
  required ParakeetModelPaths paths,
  required String wavPath,
  required int numThreads,
  required String provider,
  int iterations = 5,
}) async {
  final loadSw = Stopwatch()..start();
  final recognizer = await _createRecognizer(
    paths: paths,
    numThreads: numThreads,
    provider: provider,
  );
  loadSw.stop();

  final memBeforeWarmup = ProcessInfo.currentRss;

  // Warmup — first call pays JIT + init costs we don't want to time.
  final warmup = await _transcribeOnce(recognizer, wavPath);

  final memAfterWarmup = ProcessInfo.currentRss;

  final samples = <int>[];
  String? lastTranscript;
  for (var i = 0; i < iterations; i++) {
    final t = await _transcribeOnce(recognizer, wavPath);
    samples.add(t.us);
    lastTranscript = t.text;
  }

  recognizer.free();

  return BenchResult(
    name: name,
    config: {
      'recognizer': 'offline',
      'model': 'nemo-parakeet-tdt-0.6b-int8',
      'provider': provider,
      'num_threads': numThreads,
      'audio_seconds': _fixtureSeconds,
      'audio_sample_rate': 16000,
      'audio_fixture': _fixtureAsset,
    },
    samplesUs: samples,
    extra: {
      'cold_load_ms': loadSw.elapsedMilliseconds,
      'warmup_ms': (warmup.us / 1000).round(),
      'rss_before_mb':
          (memBeforeWarmup / 1024 / 1024).toStringAsFixed(1),
      'rss_after_mb':
          (memAfterWarmup / 1024 / 1024).toStringAsFixed(1),
      'rtf_p50': null, // computed below
      'transcript_chars': lastTranscript?.length,
      'transcript_preview': lastTranscript == null
          ? null
          : (lastTranscript.length > 220
              ? '${lastTranscript.substring(0, 220)}…'
              : lastTranscript),
    },
  );
}

void _printResult(BenchResult r) {
  // ignore: avoid_print
  print('  ${r.prettyTable()}');
  // ignore: avoid_print
  print('    cold_load=${r.extra['cold_load_ms']}ms  '
      'warmup=${r.extra['warmup_ms']}ms  '
      'rss=${r.extra['rss_before_mb']}→${r.extra['rss_after_mb']}MB');
  // RTF = realtime factor: <1 means faster than realtime, >1 means slower.
  final rtf = r.p50Ms / 1000.0 / _fixtureSeconds;
  // ignore: avoid_print
  print('    rtf_p50=${rtf.toStringAsFixed(3)}x  '
      '(${(1 / rtf).toStringAsFixed(1)}x realtime)');
  // ignore: avoid_print
  print('    transcript: ${r.extra['transcript_preview']}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'STT bench — Parakeet offline against record_out_16k.wav',
    (tester) async {
      // sherpa-onnx native bindings need to be initialized once.
      sherpa.initBindings();

      final docsPath = await const NativePaths().applicationDocumentsPath();
      final tmpPath = await const NativePaths().temporaryPath();
      final supportPath =
          await const NativePaths().applicationSupportPath();

      // ignore: avoid_print
      print('staging parakeet model files…');
      final paths = await _stageParakeet(supportPath);

      // Stage the fixture WAV from the bundle to a real file path —
      // sherpa.readWave operates on the filesystem.
      final fixturePath = p.join(tmpPath, 'bench_record_out_16k.wav');
      await extractAsset(_fixtureAsset, fixturePath);
      final wavBytes = await File(fixturePath).length();

      // ignore: avoid_print
      print('=== STT BENCH ===');
      // ignore: avoid_print
      print('fixture: $_fixtureAsset  ${_fixtureSeconds.toStringAsFixed(2)}s  '
          '$wavBytes bytes');
      // ignore: avoid_print
      print('platform: ${Platform.operatingSystem} '
          '${Platform.operatingSystemVersion}');

      final results = <BenchResult>[];

      // Pick which config to run via --dart-define=STT_CONFIG=cpu_t2|cpu_t4|nnapi.
      // Only one runs per process — sherpa's native heap doesn't release
      // cleanly between recognizers and we OOM'd on the second create
      // (Pixel 6a, 6GB RAM, encoder.int8.onnx is 622 MB).
      const sttConfig = String.fromEnvironment(
        'STT_CONFIG',
        defaultValue: 'cpu_t2',
      );
      // ignore: avoid_print
      print('\nrunning STT_CONFIG=$sttConfig (override with --dart-define)');

      if (sttConfig == 'cpu_t2') {
        final r = await _benchConfig(
          name: 'parakeet_offline_cpu_t2',
          paths: paths,
          wavPath: fixturePath,
          numThreads: 2,
          provider: 'cpu',
        );
        results.add(r);
        _printResult(r);
      } else if (sttConfig == 'cpu_t4') {
        final r = await _benchConfig(
          name: 'parakeet_offline_cpu_t4',
          paths: paths,
          wavPath: fixturePath,
          numThreads: 4,
          provider: 'cpu',
        );
        results.add(r);
        _printResult(r);
      } else if (sttConfig == 'nnapi') {
        if (defaultTargetPlatform != TargetPlatform.android) {
          // ignore: avoid_print
          print('NNAPI requires Android — skipping');
        } else {
          try {
            final r = await _benchConfig(
              name: 'parakeet_offline_nnapi_t4',
              paths: paths,
              wavPath: fixturePath,
              numThreads: 4,
              provider: 'nnapi',
            );
            results.add(r);
            _printResult(r);
          } on Object catch (e, s) {
            // ignore: avoid_print
            print('  NNAPI failed (likely unsupported op fallback): $e');
            if (kDebugMode) {
              // ignore: avoid_print
              print(s);
            }
          }
        }
      } else if (sttConfig == 'coreml') {
        final isAppleOs = defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.macOS;
        if (!isAppleOs) {
          // ignore: avoid_print
          print('CoreML requires iOS or macOS — skipping');
        } else {
          try {
            final r = await _benchConfig(
              name: 'parakeet_offline_coreml_t4',
              paths: paths,
              wavPath: fixturePath,
              numThreads: 4,
              provider: 'coreml',
            );
            results.add(r);
            _printResult(r);
          } on Object catch (e, s) {
            // ignore: avoid_print
            print('  CoreML failed: $e');
            if (kDebugMode) {
              // ignore: avoid_print
              print(s);
            }
          }
        }
      } else {
        // ignore: avoid_print
        print('unknown STT_CONFIG=$sttConfig (cpu_t2 | cpu_t4 | nnapi)');
      }

      // Persist + summarize.
      final reportFile = await writeBenchReport(
        name: 'stt_bench',
        results: results,
        docsPath: docsPath,
        meta: {
          'fixture_asset': _fixtureAsset,
          'fixture_seconds': _fixtureSeconds,
          'fixture_bytes': wavBytes,
        },
      );

      // ignore: avoid_print
      print('\n=== SUMMARY ===');
      for (final r in results) {
        // ignore: avoid_print
        print('  ${r.prettyTable()}');
      }
      // ignore: avoid_print
      print('\nreport: ${reportFile.path}');
      // ignore: avoid_print
      print('pull with: '
          'adb shell run-as com.nj.voxsynth cat ${reportFile.path}');
      // ignore: avoid_print
      print(const JsonEncoder.withIndent('  ').convert({
        'results': results.map((r) => r.toJson()).toList(),
      }));

      // Always pass — this is a benchmark, not an assertion.
      expect(results, isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
