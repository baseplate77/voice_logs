/// Prompt templates for local-only memory extraction. Kept short and focused
/// for reliable output from Gemma 3 1B.
library;

/// First-pass prompt for durable memory extraction.
String memoryExtractionPrompt(String cleanedText, {int maxMemories = 5}) {
  return '''
Extract durable facts from this voice log as JSON. Skip errands, one-off tasks, and anything with no future value.

Return: {"memories":[{"type":"<type>","text":"<short sentence>","evidence":"<exact substring from log>"}]}
Return {"memories":[]} if nothing durable. Max $maxMemories items.

Types: fact (stable truth about the user), person (named relationship), habit (routine or schedule), plan (ongoing project or goal).

Evidence must be copied exactly from the log below.

Example:
Log: I am building VoxSynth as a local-first voice journal.
Output: {"memories":[{"type":"plan","text":"User is building VoxSynth, a local-first voice journal.","evidence":"I am building VoxSynth as a local-first voice journal"}]}

Log: Buy milk tonight.
Output: {"memories":[]}

"""
$cleanedText
"""
''';
}

/// Stricter retry when the model response was malformed or invalid.
String memoryExtractionRetryPrompt(
  String cleanedText,
  String previousResponse,
) {
  return '''
Previous response was invalid. Return exactly one valid JSON object, no markdown, no code fence:
{"memories":[{"type":"fact|person|habit|plan","text":"short sentence","evidence":"exact substring from log"}]}

Return {"memories":[]} if nothing durable. Evidence must be an exact substring.

"""
$cleanedText
"""
''';
}
