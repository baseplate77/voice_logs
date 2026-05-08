import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One bench run's results — config + raw timings + summary stats.
class BenchResult {
  BenchResult({
    required this.name,
    required this.config,
    required this.samplesUs,
    this.extra = const {},
  });

  final String name;
  final Map<String, Object?> config;
  final List<int> samplesUs;
  final Map<String, Object?> extra;

  int get n => samplesUs.length;

  double get meanMs =>
      samplesUs.fold<int>(0, (a, b) => a + b) / samplesUs.length / 1000.0;

  double get p50Ms => _percentile(samplesUs, 0.50) / 1000.0;
  double get p95Ms => _percentile(samplesUs, 0.95) / 1000.0;
  double get minMs => samplesUs.reduce((a, b) => a < b ? a : b) / 1000.0;
  double get maxMs => samplesUs.reduce((a, b) => a > b ? a : b) / 1000.0;

  static int _percentile(List<int> samples, double q) {
    final sorted = [...samples]..sort();
    final idx = ((sorted.length - 1) * q).round().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  Map<String, Object?> toJson() => {
    'name': name,
    'config': config,
    'n': n,
    'mean_ms': double.parse(meanMs.toStringAsFixed(2)),
    'p50_ms': double.parse(p50Ms.toStringAsFixed(2)),
    'p95_ms': double.parse(p95Ms.toStringAsFixed(2)),
    'min_ms': double.parse(minMs.toStringAsFixed(2)),
    'max_ms': double.parse(maxMs.toStringAsFixed(2)),
    'samples_ms': samplesUs.map((u) => u / 1000.0).toList(),
    'extra': extra,
  };

  String prettyTable() {
    return '$name  n=$n  '
        'p50=${p50Ms.toStringAsFixed(0)}ms  '
        'p95=${p95Ms.toStringAsFixed(0)}ms  '
        'mean=${meanMs.toStringAsFixed(0)}ms  '
        '[${minMs.toStringAsFixed(0)}–${maxMs.toStringAsFixed(0)}ms]';
  }
}

/// Generic timed-iteration runner. Plug a [warmup] in to exclude
/// first-call overhead; [iterations] are individually timed and
/// percentile-summarized.
class BenchRunner {
  Future<BenchResult> run({
    required String name,
    required Map<String, Object?> config,
    required Future<void> Function() iteration,
    Future<void> Function()? warmup,
    int iterations = 5,
    int warmupIterations = 1,
    Map<String, Object?> extra = const {},
  }) async {
    if (warmup != null) {
      for (var i = 0; i < warmupIterations; i++) {
        await warmup();
      }
    }
    final samples = <int>[];
    for (var i = 0; i < iterations; i++) {
      final sw = Stopwatch()..start();
      await iteration();
      sw.stop();
      samples.add(sw.elapsedMicroseconds);
    }
    return BenchResult(
      name: name,
      config: config,
      samplesUs: samples,
      extra: extra,
    );
  }
}

/// Persists a bench report to `<docsPath>/bench/<name>-<ts>.json` and
/// returns the file. Easy to `adb pull` after a run.
Future<File> writeBenchReport({
  required String name,
  required List<BenchResult> results,
  required String docsPath,
  Map<String, Object?> meta = const {},
}) async {
  final dir = Directory(p.join(docsPath, 'bench'));
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final timestamp = DateTime.now()
      .toIso8601String()
      .replaceAll(':', '-')
      .replaceAll('.', '-');
  final file = File(p.join(dir.path, '$name-$timestamp.json'));
  final report = <String, Object?>{
    'name': name,
    'timestamp': DateTime.now().toIso8601String(),
    'platform': Platform.operatingSystem,
    'platform_version': Platform.operatingSystemVersion,
    'meta': meta,
    'results': results.map((r) => r.toJson()).toList(),
  };
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(report),
  );
  return file;
}
