import 'dart:typed_data';

/// Durable categories of local user memory extracted from voice logs.
enum MemoryType {
  identity('identity'),
  preference('preference'),
  relationship('relationship'),
  project('project'),
  routine('routine'),
  place('place'),
  eventContext('event_context'),
  decision('decision'),
  task('task'),
  goal('goal'),
  idea('idea'),
  reminder('reminder');

  const MemoryType(this.wire);

  final String wire;

  static MemoryType? fromWireOrNull(String value) {
    for (final type in values) {
      if (type.wire == value) return type;
    }
    return null;
  }
}

/// Lifecycle state for a memory card.
enum MemoryStatus {
  candidate('candidate'),
  active('active'),
  archived('archived'),
  deleted('deleted');

  const MemoryStatus(this.wire);

  final String wire;

  static MemoryStatus fromWire(String value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    return candidate;
  }
}

/// Privacy classification for a memory card.
enum MemorySensitivity {
  normal('normal'),
  sensitive('sensitive');

  const MemorySensitivity(this.wire);

  final String wire;

  static MemorySensitivity? fromWireOrNull(String value) {
    for (final sensitivity in values) {
      if (sensitivity.wire == value) return sensitivity;
    }
    return null;
  }
}

/// Validated memory candidate before persistence.
class MemoryCandidate {
  const MemoryCandidate({
    required this.type,
    required this.text,
    required this.evidence,
    required this.confidence,
    required this.sensitivity,
    required this.startChar,
    required this.endChar,
    this.importanceScore,
  });

  final MemoryType type;
  final String text;
  final String evidence;
  final double confidence;
  final MemorySensitivity sensitivity;
  final int startChar;
  final int endChar;
  final double? importanceScore;
}

/// Persisted memory card plus optional embedding.
class MemoryItemView {
  const MemoryItemView({
    required this.id,
    required this.type,
    required this.text,
    required this.normalizedText,
    required this.confidence,
    required this.status,
    required this.sensitivity,
    required this.firstSeenAt,
    required this.lastSeenAt,
    required this.createdAt,
    required this.updatedAt,
    required this.embedding,
    this.importanceScore,
  });

  final String id;
  final MemoryType type;
  final String text;
  final String normalizedText;
  final double confidence;
  final MemoryStatus status;
  final MemorySensitivity sensitivity;
  final DateTime firstSeenAt;
  final DateTime lastSeenAt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Float32List? embedding;
  final double? importanceScore;
}

/// A ranked memory retrieval hit.
class MemoryHit {
  const MemoryHit({
    required this.memory,
    required this.fusedScore,
    required this.matchedVia,
  });

  final MemoryItemView memory;
  final double fusedScore;
  final Set<MemoryMatchSource> matchedVia;
}

/// Retrieval paths contributing to a memory hit.
enum MemoryMatchSource { fts, vector, entity }
