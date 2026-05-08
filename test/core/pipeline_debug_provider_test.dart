import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/pipeline_debug.dart';
import 'package:voxsynth/core/pipeline_debug_provider.dart';

void main() {
  test('keeps newest pipeline debug events and clears them', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final sink = container.read(pipelineDebugSinkProvider);
    sink.record(
      logId: 'log_1',
      stage: PipelineDebugStage.recording,
      event: 'started',
      message: 'Recording started',
    );
    sink.record(
      logId: 'log_1',
      stage: PipelineDebugStage.persistence,
      event: 'succeeded',
      message: 'Saved voice log',
      elapsedMs: 12,
    );

    final entries = container.read(pipelineDebugProvider);
    expect(entries, hasLength(2));
    expect(entries.first.event, 'succeeded');
    expect(entries.first.elapsedLabel, '12ms');

    container.read(pipelineDebugProvider.notifier).clear();
    expect(container.read(pipelineDebugProvider), isEmpty);
  });

  test('caps retained pipeline debug events', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final sink = container.read(pipelineDebugSinkProvider);

    for (var i = 0; i < pipelineDebugMaxEntries + 5; i++) {
      sink.record(
        logId: 'log_$i',
        stage: PipelineDebugStage.worker,
        event: 'event_$i',
        message: 'message_$i',
      );
    }

    final entries = container.read(pipelineDebugProvider);
    expect(entries, hasLength(pipelineDebugMaxEntries));
    expect(entries.first.event, 'event_${pipelineDebugMaxEntries + 4}');
    expect(entries.last.event, 'event_5');
  });
}
