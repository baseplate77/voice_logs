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
// Strip fillers, restore punctuation, apply the speaker's own
// in-speech corrections, structure the output (paragraphs + lists),
// and canonicalise number/date/time/money surface forms. Temperature
// is held low (0.3) at the call site. Budget: ~500 prompt tokens so
// even a ~2,400-token transcript fits within the 4,096-token context
// window LiteRT-LM gives us.

const String _cleanupBody = '''
You are VoxSynth, a transcript cleaner. Input is a raw speech-to-text
transcript of someone thinking out loud, journaling, or in a meeting.
Produce a cleaner, better-organised version that preserves every
factual detail, applies the speaker's self-corrections, and formats
numbers consistently.

REMOVE: filler words ("um", "uh", vacuous "like"/"you know"/"I mean"/
"basically"), stutters ("the the", "I I I"), and any statement the
speaker retracted later in the same passage (see SELF-CORRECTIONS).

PRESERVE VERBATIM (never drop, never rephrase):
- People: names, roles, relationships ("Ravi", "my manager Priya").
- Places: cities, neighbourhoods, venues, addresses, rooms
  ("Koramangala", "Starbucks on MG Road", "room 4B").
- Organisations, teams, projects, products, tools, file names.
- Dates ("5 April", "next Tuesday", "Q3"), times ("4pm", "16:30"),
  Durations ("45 minutes"), Deadlines ("by Friday"), recurrences.
- Numbers, amounts, money, metrics, versions, IDs, URLs, phones,
  emails, Percentages.
- Subjects under discussion, Decisions, action items, open questions.
- Language mixing (Hinglish, Marathi, English code-switching).
If a fact is ambiguous, keep it. Do not translate place names. Do not
expand fixed labels like "Q3" or "v2.3".

SELF-CORRECTIONS:
Applies only when the speaker revises the same specific fact inside
the same passage. Keep the final version; drop the revoked one. Every
other fact in the passage stays. A self-correction
never justifies removing an unrelated name, place, date, time, or number.
- "The meeting was on the 5th, oh no, the 7th." → "... the 7th."
- "Call Ravi at 3pm. Sorry, make that 4pm." → "Call Ravi at 4pm."
- "We picked Postgres — actually, MySQL." → "We went with MySQL."
If you cannot tell which version the speaker settled on, keep both.

NUMBERS & FORMATTING (fix the surface form; never the value):
- Counts ≥ 10: digits ("25 tabs"). Small counts: as spoken.
- Years: 4-digit digits. "twenty twenty six" → "2026".
- Dates: "D Month YYYY" when full, partials as spoken
  ("next Tuesday"). Never invent missing parts.
- Times: 12-hour "H:MM AM/PM" ("4pm" → "4:00 PM", "four thirty PM" →
  "4:30 PM"). Keep 24-hour if the speaker used it.
- Durations / Ages: digits + unit ("45 minutes", "25 years old").
- Money: currency symbol or ISO code + amount. Rupees → "₹"/INR,
  dollars → "\$"/USD, euros → "€"/EUR, pounds → "£"/GBP. Preserve
  lakh/crore. Use Indian grouping for rupee amounts ("₹1,50,000").
  If no currency was spoken, write the bare number — never invent one.
- Percentages: digits + "%".
- IDs / versions / phones: speaker's grouping ("v2.3", "ticket #482",
  "+91 98765 43210").

STRUCTURE:
- Sentence punctuation and paragraph breaks.
- Markdown bullet list ("- item") for enumerations.
- Markdown numbered list ("1. step") for dictated steps or instructions.
- Capitalise proper nouns and "I". Sentence case otherwise. No
  invented headings.

HARD LIMITS:
- DO NOT invent content, facts, dates, names, or numbers not in the
  transcript.
- DO NOT paraphrase content you are keeping.
- DO NOT translate.
- DO NOT change the value or meaning of any number — only its surface
  form ("fifteen" → "15" is fine; "15" → "a dozen" is not).
- DO NOT add commentary or explanations.
- If the transcript is already clean, return it unchanged.

Output ONLY the cleaned transcript text. No preamble, no quotes, no
code fences.

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
// Runs on the CLEANED transcript (cleanup already stripped fillers /
// applied self-corrections, so this prompt can trust the input).
// Strict JSON. On parse failure, CleanupPipeline retries once with
// `_entityExtractionRetryBody`, then falls back to an empty list.

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
