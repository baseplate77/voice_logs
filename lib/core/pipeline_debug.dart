import 'db/job_state.dart';

/// Coarse app-pipeline stage represented in the debug UI.
enum PipelineDebugStage {
  /// User is actively recording audio.
  recording('recording', 'Recording'),

  /// Completed audio is being transcribed by local ASR.
  transcription('transcription', 'Transcription'),

  /// Raw log data is being persisted locally.
  persistence('persistence', 'Persistence'),

  /// A durable queue entry was created or recovered.
  queue('queue', 'Queue'),

  /// Gemma transcript cleanup/entity extraction.
  refine('refine', 'Refine'),

  /// e5 embedding and segment storage.
  embed('embed', 'Embed'),

  /// Entity canonicalization/linking.
  canonicalize('canonicalize', 'Canonicalize'),

  /// Local memory extraction.
  memory('memory', 'Memory'),

  /// Action item extraction.
  action('action', 'Actions'),

  /// Segment enrichment: importance scoring, topics, short summaries.
  enrich('enrich', 'Enrich'),

  /// Per-log summary generation.
  summarize('summarize', 'Summarize'),

  /// Per-entity narrative summary generation.
  entitySummary('entity_summary', 'Entity summary'),

  /// Cross-log daily / weekly digest generation.
  digest('digest', 'Digest'),

  /// Worker-level dispatch or recovery.
  worker('worker', 'Worker');

  const PipelineDebugStage(this.wire, this.label);

  /// Stable machine-readable stage name.
  final String wire;

  /// Human-readable label for the UI.
  final String label;

  /// Map a queued job type to the matching pipeline stage.
  static PipelineDebugStage fromJobType(JobType type) {
    return switch (type) {
      JobType.refine => PipelineDebugStage.refine,
      JobType.embed => PipelineDebugStage.embed,
      JobType.canonicalize => PipelineDebugStage.canonicalize,
      JobType.memory => PipelineDebugStage.memory,
      JobType.action => PipelineDebugStage.action,
      JobType.enrich => PipelineDebugStage.enrich,
      JobType.summarize => PipelineDebugStage.summarize,
      JobType.entitySummary => PipelineDebugStage.entitySummary,
      JobType.digest => PipelineDebugStage.digest,
    };
  }
}

/// One timestamped pipeline-debug event shown in the in-app debug timeline.
class PipelineDebugEntry {
  /// Creates a debug timeline entry.
  const PipelineDebugEntry({
    required this.timestamp,
    required this.stage,
    required this.event,
    required this.message,
    this.logId,
    this.jobId,
    this.attempt,
    this.elapsedMs,
  });

  /// Wall-clock time when this event was emitted.
  final DateTime timestamp;

  /// Voice log id, when the event is tied to one log.
  final String? logId;

  /// Queue job id, when the event is tied to one job row.
  final String? jobId;

  /// Pipeline stage this event belongs to.
  final PipelineDebugStage stage;

  /// Short event verb such as `started`, `succeeded`, or `failed`.
  final String event;

  /// Human-readable details. Must avoid user transcript/audio content.
  final String message;

  /// One-based attempt count for worker jobs, when relevant.
  final int? attempt;

  /// Duration in milliseconds for completed timed work, when available.
  final int? elapsedMs;

  /// Compact elapsed-duration label for UI display.
  String get elapsedLabel {
    final ms = elapsedMs;
    if (ms == null) return '';
    if (ms >= 1000) {
      final seconds = ms / 1000;
      return '${seconds.toStringAsFixed(seconds >= 10 ? 1 : 2)}s';
    }
    return '${ms}ms';
  }
}

/// Sink used by non-UI pipeline code to publish debug timeline events.
abstract class PipelineDebugSink {
  /// Add a fully-formed debug event.
  void add(PipelineDebugEntry entry);
}

/// Convenience helpers for emitting timestamped debug events.
extension PipelineDebugSinkRecording on PipelineDebugSink {
  /// Timestamp and add a debug event.
  void record({
    required PipelineDebugStage stage,
    required String event,
    required String message,
    String? logId,
    String? jobId,
    int? attempt,
    int? elapsedMs,
  }) {
    add(
      PipelineDebugEntry(
        timestamp: DateTime.now(),
        logId: logId,
        jobId: jobId,
        stage: stage,
        event: event,
        message: message,
        attempt: attempt,
        elapsedMs: elapsedMs,
      ),
    );
  }
}

/// No-op debug sink for tests and code paths that do not need UI logging.
final class NoopPipelineDebugSink implements PipelineDebugSink {
  /// Creates a sink that drops all debug entries.
  const NoopPipelineDebugSink();

  @override
  void add(PipelineDebugEntry entry) {}
}
