/// Prompt shapes for the refine pipeline. Kept as top-level const
/// strings so each renders into a unit-testable function and the
/// surface area is auditable in one place.
library;

/// System + user instruction for the first-pass `record_log` call.
/// Renders into a single prompt string — flutter_gemma doesn't expose
/// a system-role channel on the litertlm bundle so we inline it.
String recordLogPrompt(String rawTranscript) {
  return '''
You are a voice-log analyzer. Given a raw voice transcript, produce a
cleaned version and extract entities. Respond with a single JSON object
that matches this schema exactly — no commentary, no markdown fences:

{
  "cleaned_text": "<punctuated; disfluencies removed; numbers normalized>",
  "entities": [
    { "text": "<surface text as it appears in cleaned_text>",
      "type": "PERSON|PLACE|PROJECT|DURATION|TIME|NUMBER|OTHER" }
  ]
}

Do not include character offsets — they are recovered post-hoc.

Raw transcript:
"""
$rawTranscript
"""
''';
}

/// Stricter retry when the first pass returned malformed JSON.
String recordLogRetryPrompt(String rawTranscript, String previousResponse) {
  return '''
Your previous response was not valid JSON. Respond with exactly one
JSON object matching:

{ "cleaned_text": "<text>", "entities": [ { "text": "<text>", "type": "<TYPE>" } ] }

No markdown. No extra commentary. Re-extract the record_log for this
transcript:
"""
$rawTranscript
"""

Previous (invalid) response for reference only:
$previousResponse
''';
}
