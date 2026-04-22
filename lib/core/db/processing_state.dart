/// State machine for a voice log's background processing pipeline.
/// Persisted as its [wire] string in `voice_logs.processing_state`.
enum ProcessingState {
  /// Just recorded — raw transcript present, refine job not yet run.
  recorded('recorded'),

  /// Gemma has produced `cleaned_text` and entity mentions.
  refined('refined'),

  /// Per-segment embeddings are in the vector index.
  embedded('embedded'),

  /// A pipeline stage failed; `error_message` holds the detail.
  failed('failed');

  const ProcessingState(this.wire);

  /// String stored in SQLite.
  final String wire;

  /// Parse a wire value back into an enum, returning [failed] on unknown
  /// input (defensive — if a future migration introduces a new state, old
  /// code won't crash).
  static ProcessingState fromWire(String value) {
    for (final v in values) {
      if (v.wire == value) return v;
    }
    return failed;
  }
}
