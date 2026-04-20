import '../../llm/prompt_templates.dart';

/// Hard cap on the profile's output size — matches the plan's
/// "≤300 tokens" constraint so the always-on injection doesn't crowd
/// out retrieved chunks in the 8k Gemma context. We ask for ~200 words
/// which tokenises to roughly 250-280 tokens on Gemma's SP model.
const int kProfileSummaryTargetWords = 200;

/// Compile the always-on "about me" from top active facts + open
/// goals + recent decisions. Deterministic (temperature 0.2) so
/// successive rebuilds after small memory changes don't jitter the
/// whole blurb.
const String _profileBuildBody = '''
You are VoxSynth. Compile an "about the user" summary from the memory
records below. The summary is injected as context into every future
question, so it must be compact, neutral, and grounded in the records
— no speculation.

Output ONLY the summary text (no JSON, no list markers, no preamble).
Target ~200 words. Group related facts; fold redundancies; prefer
active voice.

Active facts:
{{facts}}

Open / in-progress goals:
{{goals}}

Recent decisions (newest first):
{{decisions}}
''';

const PromptTemplate profileBuildTemplate = PromptTemplate(
  name: 'profile_build',
  body: _profileBuildBody,
  requiredVariables: <String>['facts', 'goals', 'decisions'],
);
