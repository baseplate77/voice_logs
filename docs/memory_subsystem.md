# VoxSynth local memory subsystem

The memory subsystem is a planned local-only layer that turns refined voice logs into durable, searchable user context. It must preserve VoxSynth's privacy model: no cloud, no telemetry, no network calls, encrypted persistence, and on-device inference only.

## Goals

- Capture durable facts, preferences, relationships, projects, routines, places, and useful ongoing context from voice logs.
- Keep every memory evidence-backed by one or more source voice logs.
- Make memory retrievable for search, summaries, and future assistant-style experiences without sending user data off device.
- Give users clear control to inspect, edit, merge, delete, export, or disable memory.
- Treat sensitive memories conservatively and require explicit user review before use.

## Non-goals for v1

- Cross-device sync.
- Cloud backup.
- Server-side memory or personalization.
- Inferring sensitive traits from weak evidence.
- Blocking the record-stop path on memory extraction.

## Pipeline placement

Memory extraction runs after refinement, embedding, and entity canonicalization:

```text
Record
  -> raw transcript persisted and searchable
  -> Gemma refinement
  -> entity extraction
  -> segment embeddings
  -> entity canonicalization
  -> memory extraction and update
```

The memory step is a background job. It must never affect the requirement that recording stop returns the user to the home list within 500 ms.

## Memory model

A memory is a small card-like record:

```text
MemoryItem
- id
- type
- text
- normalized_text
- confidence
- status
- sensitivity
- first_seen_at
- last_seen_at
- created_at
- updated_at
```

Recommended memory types:

```text
identity        stable facts about the user
preference      likes, dislikes, and preferences
relationship    people and the user's relationship to them
project         ongoing projects, goals, or responsibilities
routine         repeated habits or schedules
place           meaningful locations
event_context   past context useful for future recall
```

Recommended statuses:

```text
candidate   extracted but not yet trusted
active      usable for retrieval
archived    superseded or stale
deleted     user-forgotten and never retrieved
```

Recommended sensitivity levels:

```text
normal
sensitive
```

Sensitive categories include health, finances, religion, politics, sexuality, legal issues, precise addresses, credentials, and secrets.

## Storage design

Add Drift tables when the feature is implemented:

```text
MemoryItems
- id
- type
- text
- normalized_text
- confidence
- status
- sensitivity
- first_seen_at
- last_seen_at
- created_at
- updated_at

MemorySources
- memory_id
- voice_log_id
- start_char
- end_char
- evidence_text

MemoryEntityLinks
- memory_id
- canonical_entity_id

MemoryEmbeddings
- memory_id
- embedding vector(384)
```

Indexing:

```text
memory_items_fts(text, normalized_text)
memory_vec(memory_id, embedding)
```

Embeddings use the existing e5-small-v2 path:

```text
passage: <memory text>
```

Queries use:

```text
query: <user query>
```

All memory tables and embeddings live in the encrypted local database.

## Extraction

Gemma should run a strict function-call-style prompt over `cleaned_text` after refinement:

```text
Extract durable memories from this voice journal entry.

Only include facts useful in the future.
Do not include one-off events unless they explain an ongoing goal, project, preference, relationship, or routine.
Do not guess.
Return JSON only.

Input:
<cleaned_text>

Return:
{
  "memories": [
    {
      "type": "identity|preference|relationship|project|routine|place|event_context",
      "text": "...",
      "evidence": "...",
      "confidence": 0.0,
      "sensitivity": "normal|sensitive"
    }
  ]
}
```

Dart validation rules:

- JSON must parse cleanly.
- Enum values must be allow-listed.
- Evidence text must be recoverable from `cleaned_text` with forward-scan matching.
- Confidence must meet the configured threshold.
- Cap extracted memories per log to a small number, such as five.
- Sensitive memories enter `candidate` status unless the user confirms them.

## Deduplication and updates

Before inserting a candidate memory:

1. Embed the candidate with `embedPassages`.
2. Search existing active and candidate memories by vector similarity.
3. Check FTS overlap on `text` and `normalized_text`.
4. If a strong match exists, update the existing memory rather than inserting a duplicate.
5. Add a new `MemorySources` row for the latest evidence.
6. Refresh `last_seen_at`, confidence, and linked entities.

A memory can become active when confidence is high, it appears across multiple logs, or the user manually confirms it.

## Retrieval

Memory retrieval should use the same hybrid shape as log search:

```text
query
  -> FTS memory search
  -> vector memory search
  -> entity-linked memory boost
  -> confidence/source-count/recency boost
  -> top memory cards
```

Use Reciprocal Rank Fusion with the existing `k=60` convention. Keep Gemma prompt context small because the bundled LiteRT-LM max token limit is fixed at 2048. A typical prompt should include only the top 8-12 short memory cards.

Example context block:

```text
Relevant user memory:
- User is building VoxSynth, a local-first Flutter voice journal app.
- Shivani is the user's coworker.
- User prefers privacy-preserving, on-device apps.
```

## User controls

The app should expose a Memory screen and settings:

```text
Memory on/off
Auto-save memories on/off
Review sensitive memories before saving
Delete all memories
Export memories
```

Each memory item should support:

```text
view source logs
edit
merge
delete
pin or confirm
archive
```

Deleting a memory removes the memory row, source links, and memory embedding. It does not delete the original voice log unless the user separately chooses to delete that log.

## Safety and privacy rules

- Never use deleted memories in retrieval.
- Never use unconfirmed sensitive memories in Gemma prompts.
- Never infer sensitive traits from weak evidence.
- Store source evidence so users can audit why a memory exists.
- Keep memory jobs on the single-worker isolate queue with Gemma inference serialized.
- No network calls, sync SDKs, analytics, crash reporters, or remote model APIs.

## Planned implementation files

```text
lib/features/memory/
  memory_extractor.dart
  memory_repository.dart
  memory_retriever.dart
  memory_types.dart
  memory_screen.dart

lib/core/db/schema/
  memory_items.dart
  memory_sources.dart
  memory_entity_links.dart
```

Tests:

```text
test/features/memory/memory_extractor_test.dart
test/features/memory/memory_repository_test.dart
test/features/memory/memory_retriever_test.dart
test/no_network_test.dart
```
