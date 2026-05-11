/// State machine for a [ProcessingJobs] row. Persisted as [wire].
enum JobState {
  /// Waiting to be picked up by the worker.
  pending('pending'),

  /// Currently executing. On crash-recovery, any `running` job is reset
  /// to `pending` so the worker retries it.
  running('running'),

  /// Completed successfully.
  done('done'),

  /// Gave up after exhausting retries.
  failed('failed');

  const JobState(this.wire);

  final String wire;

  static JobState fromWire(String value) {
    for (final v in values) {
      if (v.wire == value) return v;
    }
    return failed;
  }
}

/// Kinds of job the worker knows how to dispatch. Stored on
/// `processing_jobs.job_type` as [wire].
enum JobType {
  /// Gemma cleanup — raw transcript → cleaned text + entities.
  refine('refine'),

  /// e5 segment embedding.
  embed('embed'),

  /// Canonical entity linking.
  canonicalize('canonicalize'),

  /// Durable local memory extraction.
  memory('memory'),

  /// Segment enrichment: importance scoring, topics, short summaries.
  enrich('enrich'),

  /// Per-log summary generation.
  summarize('summarize');

  const JobType(this.wire);

  final String wire;

  static JobType? fromWireOrNull(String value) {
    for (final v in values) {
      if (v.wire == value) return v;
    }
    return null;
  }
}
