import '../../llm/prompt_templates.dart';

/// Extract durable memories from a cleaned transcript. Output is a
/// strict JSON object with four arrays, one per memory kind.
///
/// Tuned for Gemma 3 1B IT at temperature 0.2 (see
/// `kBackgroundJobTemperature` — we reuse the same low-temperature
/// setting for determinism). On malformed JSON the extractor retries
/// once with [memoryExtractionRetryTemplate], then falls back to an
/// empty list with a logged warning.
const String _memoryExtractionBody = '''
You are VoxSynth's memory extractor. Given a cleaned voice-log
transcript below, distil it into durable memories the user wants to
carry across sessions.

Extract FOUR kinds:
  - "facts": stable propositions about the user or their world
    (e.g. "I work at Acme as a senior PM").
  - "decisions": timestamped choices the user announced
    (e.g. "I decided to migrate the ingest pipeline to Postgres").
  - "episodes": narrative events tied to a moment
    (e.g. "Had a hard 1:1 with Priya on Monday about scope creep").
  - "goals": ongoing objectives
    (e.g. "Ship VoxSynth v1 by 2026-06-01").

Output ONLY a single JSON object, no prose, no markdown fences, in
this exact shape:
  {
    "facts": [
      {"title": "<= 10 words",
       "content": "1-3 sentences, canonical phrasing",
       "confidence": 0.0-1.0,
       "entity_names": ["CanonicalEntity", ...]}
    ],
    "decisions": [
      {"title": "<= 10 words",
       "content": "1-3 sentences",
       "occurred_at": "YYYY-MM-DD" or null,
       "confidence": 0.0-1.0,
       "entity_names": ["CanonicalEntity", ...]}
    ],
    "episodes": [
      {"title": "<= 10 words",
       "content": "1-3 sentences",
       "occurred_at": "YYYY-MM-DD",
       "confidence": 0.0-1.0,
       "entity_names": ["CanonicalEntity", ...]}
    ],
    "goals": [
      {"title": "<= 10 words",
       "content": "1-3 sentences",
       "state": "open" | "in_progress" | "done" | "abandoned",
       "due_at": "YYYY-MM-DD" or null,
       "confidence": 0.0-1.0,
       "entity_names": ["CanonicalEntity", ...]}
    ]
  }

Rules:
- Skip trivial or single-mention observations. Only emit memories the
  user would plausibly want to recall across sessions.
- Be conservative on confidence: 0.8+ only when the transcript is
  unambiguous; 0.5-0.7 for inferred; < 0.5 should not be emitted.
- "entity_names" must reference names from the canonical entity list
  below. Drop unmatched names.
- Dates must be absolute (resolve "yesterday" → "{{recording_date}}"'s
  previous day etc.). If you cannot resolve, use null where allowed,
  skip the memory where required.
- Empty arrays are acceptable when no memories of that kind apply.

Recording date (today): {{recording_date}}

Canonical entities in this transcript:
{{entities}}

Cleaned transcript:
{{transcript}}
''';

const PromptTemplate memoryExtractionTemplate = PromptTemplate(
  name: 'memory_extraction',
  body: _memoryExtractionBody,
  requiredVariables: <String>['recording_date', 'entities', 'transcript'],
);

const String _memoryExtractionRetryBody = '''
Your previous response was not valid JSON. Respond with ONLY a JSON
object. No markdown, no code fences, no prose before or after. Use the
exact shape below; each array may be empty:

{
  "facts": [...],
  "decisions": [...],
  "episodes": [...],
  "goals": [...]
}

Every element must include "title" (string), "content" (string),
"confidence" (number 0-1), "entity_names" (array of string). Kind-
specific fields as described previously ("occurred_at", "due_at",
"state").

Recording date: {{recording_date}}

Cleaned transcript:
{{transcript}}
''';

const PromptTemplate memoryExtractionRetryTemplate = PromptTemplate(
  name: 'memory_extraction_retry',
  body: _memoryExtractionRetryBody,
  requiredVariables: <String>['recording_date', 'transcript'],
);
