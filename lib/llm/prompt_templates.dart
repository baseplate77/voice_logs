/// Strongly-typed, validated prompt templates.
///
/// IMPLEMENTATION_PLAN §4 calls these out specifically — keep prompts as
/// top-level const strings rather than inlined `'blah $x'` strings, so we
/// can unit-test them and pin their behaviour. [PromptTemplate] threads a
/// name, body, and required-variable list together; rendering fails fast
/// if a variable is missing.
library;

/// A template backed by a raw string with `{{variable}}` placeholders.
///
/// ```dart
/// final rendered = cleanupTemplate.render({'transcript': 'um hello'});
/// ```
///
/// If any [requiredVariables] key is missing from the render map,
/// [render] throws [ArgumentError] — templates are programmer-owned so
/// missing vars are bugs, not recoverable failures.
final class PromptTemplate {
  const PromptTemplate({
    required this.name,
    required this.body,
    required this.requiredVariables,
  });

  /// Stable identifier used in logs ("cleanup", "chunk_boundaries", etc.)
  final String name;

  /// The raw template with `{{var}}` holes.
  final String body;

  /// Every variable that MUST be present at render time.
  final List<String> requiredVariables;

  /// Substitute `{{var}}` for each entry in [vars]. Throws if a required
  /// variable is missing.
  String render(Map<String, String> vars) {
    for (final req in requiredVariables) {
      if (!vars.containsKey(req)) {
        throw ArgumentError(
          'Prompt "$name" missing required variable: $req',
        );
      }
    }
    var out = body;
    for (final entry in vars.entries) {
      out = out.replaceAll('{{${entry.key}}}', entry.value);
    }
    return out;
  }
}

// ─── cleanup template ─────────────────────────────────────────────
// Strip fillers, restore punctuation, DO NOT paraphrase. Temperature is
// held low (0.3) at the call site; this prompt structure is what makes
// re-runs on the same input deterministic to within ~5% edit distance.

const String _cleanupBody = '''
You are VoxSynth, a transcript cleaner. Input is a raw speech-to-text
transcript from a person talking to themselves or in a meeting. Your
job is to produce a faithfully-cleaned version:

Rules:
- Remove filler words: "um", "uh", "like" (only when meaningless), "you know", "I mean", "sort of", "kind of" when vacuous.
- Add sentence-ending punctuation. Break run-on sentences.
- DO NOT paraphrase. DO NOT invent content.
- DO NOT remove hesitations that carry meaning ("Actually, I think…").
- Keep named entities verbatim.
- Preserve language mixing (Hinglish, Marathi code-switching) if present.
- If the transcript is already clean, return it unchanged.

Output ONLY the cleaned transcript text. No preamble, no explanations,
no wrapping quotes.

Raw transcript:
{{transcript}}
''';

const PromptTemplate cleanupTemplate = PromptTemplate(
  name: 'cleanup',
  body: _cleanupBody,
  requiredVariables: <String>['transcript'],
);

// ─── chunk boundaries template ────────────────────────────────────
// The LLM picks semantic boundaries as character offsets into the
// cleaned text. We validate ranges in TopicChunker and fall back to
// fixed-width chunks if the output is malformed.

const String _chunkBoundariesBody = '''
You are a transcript segmenter. Given a cleaned transcript, identify
natural topic boundaries. Each chunk should cover one coherent
discussion (50–500 words).

Output ONLY a JSON array, no prose. Each element has:
  {"start": int (char offset), "end": int (char offset, exclusive),
   "topic": "short label (max 5 words)"}

Boundaries must be non-overlapping, ordered, and together cover the
full transcript. Use word-boundary offsets (do not split words).

Transcript (offsets shown for reference every 200 chars with "⟨N⟩"):
{{annotated_transcript}}
''';

const PromptTemplate chunkBoundariesTemplate = PromptTemplate(
  name: 'chunk_boundaries',
  body: _chunkBoundariesBody,
  requiredVariables: <String>['annotated_transcript'],
);

// ─── entity extraction template ───────────────────────────────────
// Strict JSON. On parse failure, CleanupPipeline retries once with a
// stricter prompt (see _entityExtractionRetryBody below), then falls
// back to an empty list.

const String _entityExtractionBody = '''
Extract named entities from the transcript. Focus on:
  - people (colleagues, collaborators) → kind="person"
  - organizations / teams → kind="organization"
  - project names → kind="project"
  - products / features → kind="product"
  - explicit decisions made ("we decided X") → kind="decision"
  - domain concepts recurring in discussion → kind="concept"

Output ONLY a JSON array, no prose. Each element has:
  {"name": "Canonical form",
   "kind": "<one of above>",
   "aliases": ["variant", ...],
   "salience": 0.0–1.0}

Skip entities mentioned once without context. Include salience as your
best guess of centrality.

Transcript:
{{transcript}}
''';

const PromptTemplate entityExtractionTemplate = PromptTemplate(
  name: 'entity_extraction',
  body: _entityExtractionBody,
  requiredVariables: <String>['transcript'],
);

const String _entityExtractionRetryBody = '''
Your previous response was not valid JSON. Respond with ONLY a JSON
array. No markdown, no code fences, no prose before or after. Empty
array [] is acceptable if there are no entities.

Each element MUST have exactly these keys: "name" (string), "kind"
(string), "aliases" (array of string), "salience" (number 0-1).

Transcript:
{{transcript}}
''';

const PromptTemplate entityExtractionRetryTemplate = PromptTemplate(
  name: 'entity_extraction_retry',
  body: _entityExtractionRetryBody,
  requiredVariables: <String>['transcript'],
);

// ─── tags template ────────────────────────────────────────────────

const String _tagsBody = '''
Suggest 1–4 short topic tags (lowercase, single or hyphenated words)
that summarise this transcript at the document level. Output ONLY a
JSON array of strings. No prose.

Transcript:
{{transcript}}
''';

const PromptTemplate tagsTemplate = PromptTemplate(
  name: 'tags',
  body: _tagsBody,
  requiredVariables: <String>['transcript'],
);
