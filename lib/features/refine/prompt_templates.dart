/// Prompt shapes for the refine pipeline. Kept as top-level const
/// strings so each renders into a unit-testable function and the
/// surface area is auditable in one place.
library;

/// System + user instruction for the first-pass `record_log` call.
/// Renders into a single prompt string — flutter_gemma doesn't expose
/// a system-role channel on the litertlm bundle so we inline it.
String recordLogPrompt(String rawTranscript) {
  return '''
Clean this English voice transcript and extract important entities.
Return ONLY compact JSON. No markdown. No commentary.

Schema:
{"cleaned_text":"<punctuated transcript, filler words removed>","entities":[{"text":"<exact substring in cleaned_text>","type":"PERSON|PLACE|PROJECT|DURATION|TIME|NUMBER|OTHER"}]}

Rules:
- Keep the same meaning. Do not summarize or add facts.
- Keep cleaned_text close to the transcript length.
- Include at most 20 entities. Use [] if none.
- Do not include character offsets.

Transcript:
"""
$rawTranscript
"""
''';
}

/// Stricter retry when the first pass returned malformed JSON.
String recordLogRetryPrompt(String rawTranscript, String previousResponse) {
  return '''
The previous answer was invalid JSON. Return ONLY this compact JSON shape:
{"cleaned_text":"<text>","entities":[{"text":"<text>","type":"PERSON|PLACE|PROJECT|DURATION|TIME|NUMBER|OTHER"}]}

Transcript:
"""
$rawTranscript
"""

Invalid previous answer:
$previousResponse
''';
}
