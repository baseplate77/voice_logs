import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pipeline_debug.dart';

/// Maximum number of in-memory debug events retained for the UI timeline.
const pipelineDebugMaxEntries = 300;

/// In-memory controller for pipeline debug events shown in the UI.
class PipelineDebugController extends StateNotifier<List<PipelineDebugEntry>>
    implements PipelineDebugSink {
  /// Creates an empty pipeline debug timeline.
  PipelineDebugController() : super(const []);

  @override
  void add(PipelineDebugEntry entry) {
    final next = [entry, ...state];
    state = next.length > pipelineDebugMaxEntries
        ? List<PipelineDebugEntry>.unmodifiable(
            next.take(pipelineDebugMaxEntries),
          )
        : List<PipelineDebugEntry>.unmodifiable(next);
  }

  /// Remove all retained debug events.
  void clear() => state = const [];
}

/// UI-readable pipeline debug event stream.
final pipelineDebugProvider =
    StateNotifierProvider<PipelineDebugController, List<PipelineDebugEntry>>(
      (ref) => PipelineDebugController(),
    );

/// Injectable sink for pipeline code that should not depend on UI widgets.
final pipelineDebugSinkProvider = Provider<PipelineDebugSink>((ref) {
  return ref.watch(pipelineDebugProvider.notifier);
});
