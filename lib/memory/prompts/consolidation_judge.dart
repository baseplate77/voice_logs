import '../../llm/prompt_templates.dart';

/// Gate the LLM-expensive deduplication judge behind a cheap cosine
/// prefilter. Only neighbours within this similarity are sent to the
/// judge. Tuned so true duplicates (the same idea rephrased) pass but
/// clearly distinct memories don't burn LLM cycles.
const double kConsolidationMergeThreshold = 0.85;

/// Classify whether a newly-extracted memory is a duplicate of an
/// existing one, contradicts it, or is actually unrelated (the cosine
/// prefilter is fast but not perfect). The verdict drives insert /
/// merge / supersede.
const String _consolidationJudgeBody = '''
You are VoxSynth's deduplicator. Two memory records are below. Decide
whether they refer to the same underlying fact/decision/episode/goal.

Possible verdicts:
  - "duplicate": the NEW record says the same thing as the EXISTING
    one (possibly with more detail). The store should MERGE them.
  - "contradiction": the NEW record updates or overrides the EXISTING
    one (e.g. changed mind, new date, new state). The EXISTING record
    should be SUPERSEDED.
  - "unrelated": distinct memories that happened to share vocabulary.
    Both should stay.

Output ONLY a single JSON object:
  {"verdict": "duplicate" | "contradiction" | "unrelated",
   "rationale": "<= 20 words"}

EXISTING memory ({{existing_kind}}):
  title:   {{existing_title}}
  content: {{existing_content}}

NEW memory ({{new_kind}}):
  title:   {{new_title}}
  content: {{new_content}}
''';

const PromptTemplate consolidationJudgeTemplate = PromptTemplate(
  name: 'consolidation_judge',
  body: _consolidationJudgeBody,
  requiredVariables: <String>[
    'existing_kind',
    'existing_title',
    'existing_content',
    'new_kind',
    'new_title',
    'new_content',
  ],
);
