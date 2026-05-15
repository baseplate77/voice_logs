/// User-facing action categories extracted from voice logs.
enum VoiceActionType {
  task('task'),
  reminder('reminder'),
  decision('decision'),
  followUp('follow_up');

  const VoiceActionType(this.wire);

  final String wire;

  static VoiceActionType? fromWireOrNull(String value) {
    for (final type in values) {
      if (type.wire == value) return type;
    }
    return null;
  }
}

/// Lifecycle for an extracted action item.
enum VoiceActionStatus {
  pending('pending'),
  done('done'),
  archived('archived');

  const VoiceActionStatus(this.wire);

  final String wire;

  static VoiceActionStatus fromWire(String value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return pending;
  }
}

/// Validated action item before persistence.
class VoiceActionCandidate {
  const VoiceActionCandidate({
    required this.type,
    required this.title,
    required this.evidence,
    required this.startChar,
    required this.endChar,
    this.notes,
    this.dueAt,
    this.confidence = 0.8,
  });

  final VoiceActionType type;
  final String title;
  final String? notes;
  final DateTime? dueAt;
  final String evidence;
  final int startChar;
  final int endChar;
  final double confidence;
}

/// Persisted action item consumed by the UI.
class VoiceActionItemView {
  const VoiceActionItemView({
    required this.id,
    required this.voiceLogId,
    required this.type,
    required this.title,
    required this.notes,
    required this.dueAt,
    required this.status,
    required this.notificationId,
    required this.notificationScheduledAt,
    required this.evidenceText,
    required this.startChar,
    required this.endChar,
    required this.confidence,
    required this.createdAt,
    required this.updatedAt,
    required this.completedAt,
  });

  final String id;
  final String voiceLogId;
  final VoiceActionType type;
  final String title;
  final String? notes;
  final DateTime? dueAt;
  final VoiceActionStatus status;
  final int? notificationId;
  final DateTime? notificationScheduledAt;
  final String evidenceText;
  final int startChar;
  final int endChar;
  final double confidence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
}
