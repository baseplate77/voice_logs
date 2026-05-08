/// Prompt templates for local-only memory extraction.
library;

/// First-pass prompt for durable memory extraction.
String memoryExtractionPrompt(String cleanedText) {
  return '''
You are a local-only voice-journal memory extractor. Extract durable memories
from the cleaned voice log. Only include facts useful in the future. Do not
include one-off events unless they explain an ongoing goal, project,
preference, relationship, place, routine, or durable context. Do not guess.
Do not infer sensitive traits. Return exactly one JSON object, no markdown and
no commentary.

Allowed memory types:
identity, preference, relationship, project, routine, place, event_context

Allowed sensitivity values:
normal, sensitive

Schema:
{
  "memories": [
    {
      "type": "identity|preference|relationship|project|routine|place|event_context",
      "text": "short user-facing memory sentence",
      "evidence": "exact substring from the cleaned log",
      "confidence": 0.0,
      "sensitivity": "normal|sensitive"
    }
  ]
}

Cleaned voice log:
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
Your previous response was not valid for the requested JSON schema. Respond
with exactly one JSON object and no markdown:

{ "memories": [ { "type": "preference", "text": "...", "evidence": "exact substring", "confidence": 0.85, "sensitivity": "normal" } ] }

Use only exact evidence substrings from this cleaned voice log:
"""
$cleanedText
"""

Previous invalid response for reference only:
$previousResponse
''';
}
