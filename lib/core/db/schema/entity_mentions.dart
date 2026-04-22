import 'package:drift/drift.dart';

import 'voice_logs.dart';

/// One row per entity mention extracted from a voice log. Character offsets
/// are recovered in Dart via forward-scan matching against `cleaned_text`
/// (the LLM does not emit offsets — see CLAUDE.md).
class EntityMentions extends Table {
  /// UUID v4.
  TextColumn get id => text()();

  /// Owning voice log.
  TextColumn get logId => text().references(VoiceLogs, #id)();

  /// The surface text of the mention (as it appears in `cleaned_text`).
  /// Dart-side getter renamed to avoid colliding with `Table.text()`; the
  /// SQL column is still named `text`.
  TextColumn get mentionText => text().named('text')();

  /// One of: `PERSON` | `PLACE` | `PROJECT` | `DURATION` | `TIME` | `NUMBER`
  /// | `OTHER`.
  TextColumn get type => text()();

  /// Inclusive start offset into `voice_logs.cleaned_text`.
  IntColumn get charStart => integer()();

  /// Exclusive end offset into `voice_logs.cleaned_text`.
  IntColumn get charEnd => integer()();

  /// Canonical entity this mention has been linked to, or `NULL` if not yet
  /// canonicalized.
  TextColumn get canonicalEntityId => text().nullable()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}
