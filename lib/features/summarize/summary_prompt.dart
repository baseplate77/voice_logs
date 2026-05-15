/// Prompt shapes for the per-log summarize stage.
library;

/// Low-temperature structured generation matches the rest of the refine
/// pipeline for Gemma 3 1B JSON tasks.
const double kSummarizeTemperature = 0;

/// Primary summarize prompt. Asks for a single minified JSON object covering
/// one-liner, bullets, people/projects, decisions, and follow-ups. Every list
/// may be empty; the one-liner is the only required field.
String summarizeLogPrompt(String cleanedText) {
  return '''
You are VoxSynth's local journal summarizer.
Read the voice log below and produce a structured summary.

Return exactly one minified JSON object and nothing else:
{"one_liner":"...","bullets":["...","..."],"people_projects":["..."],"decisions":["..."],"follow_ups":["..."]}

If any string contains Markdown line breaks, encode them inside the JSON string as \\n. Do not put raw unescaped line breaks inside a JSON string.

Rules:
- one_liner: one short sentence (max ~120 chars) describing what the log is about.
- bullets: 3 short factual bullets capturing the key points of the log. No leading dashes or bullets — plain sentences.
- people_projects: distinct named people, projects, products, or organizations actually mentioned. No pronouns. Use the exact spelling from the cleaned text.
- decisions: concrete decisions made, conclusions reached, or commitments stated in this log. Empty array if none.
- follow_ups: action items, tasks, reminders, or "things to do later" stated in this log. Empty array if none.
- Never invent details that are not in the log. If a field has nothing to say, return an empty array.
- Use plain English in every string. Do not include speaker tags, timestamps, or transcript filler.

Example
Cleaned text:
"""
I talked to Raj about the app launch. The investor deck still needs updates and the launch target is next Friday. Raj will review the pricing draft I send him.
"""
Output: {"one_liner":"Discussed app launch planning with Raj.","bullets":["Investor deck needs updates.","Launch target is next Friday.","Raj will review pricing."],"people_projects":["Raj"],"decisions":["Launch target set to next Friday."],"follow_ups":["Update investor deck.","Send Raj pricing draft."]}

Cleaned text:
"""
$cleanedText
"""
''';
}

/// Stricter retry for parse failures. Reminds the model of the exact schema
/// and reproduces the offending response so the next attempt can correct it.
String summarizeLogRetryPrompt(String cleanedText, String previousResponse) {
  return '''
Your previous response was invalid. Return exactly one valid minified JSON object with these five keys and no markdown, no prose, no code fence:
{"one_liner":"...","bullets":["..."],"people_projects":["..."],"decisions":["..."],"follow_ups":["..."]}

Every list must be a JSON array of strings (empty array allowed). one_liner must be a single short sentence string.

Cleaned text:
"""
$cleanedText
"""

Invalid previous response:
$previousResponse
''';
}
