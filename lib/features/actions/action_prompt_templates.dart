/// Prompt shapes for extracting user-facing actions from voice logs.
library;

/// Low temperature because the output is strict JSON.
const double kActionExtractionTemperature = 0.1;

/// Ask the local LLM to extract tasks, reminders, decisions, and follow-ups.
String actionExtractionPrompt({
  required String cleanedText,
  required DateTime now,
}) {
  return '''
You are VoxSynth's local action extractor.
Extract only actionable items from this cleaned English voice journal entry.

Current local time: ${now.toIso8601String()}

Return exactly one minified JSON object and nothing else:
{"actions":[{"type":"task|reminder|decision|follow_up","title":"...","notes":"...","due_at":"YYYY-MM-DDTHH:MM:SS","evidence":"...","confidence":0.0}]}

Rules:
- Every evidence value must be copied exactly from the transcript.
- Extract tasks, reminders, commitments, explicit decisions, and follow-ups.
- Use reminder when there is a due date/time or the user says remind/remember.
- Use decision for phrases like "I decided", "we decided", "the decision is".
- Use follow_up for calling, replying, sending, checking in, or following up.
- Use task for other concrete to-dos.
- Do not extract vague thoughts, feelings, facts, memories, or generic ideas with no action.
- Do not invent due_at. If no due date/time is stated, omit due_at.
- Resolve relative dates like tomorrow, Friday, next week using Current local time.
- Keep title short and user-facing. Use notes only when useful.
- Include at most 8 actions.
- If there are no actions, return {"actions":[]}.

Examples:
Transcript: Tasks for tomorrow: Call Dr. Rao at 9:30. Send Project Atlas notes to Shivani.
Output: {"actions":[{"type":"reminder","title":"Call Dr. Rao","due_at":"2026-05-15T09:30:00","evidence":"Call Dr. Rao at 9:30","confidence":0.92},{"type":"task","title":"Send Project Atlas notes to Shivani","evidence":"Send Project Atlas notes to Shivani","confidence":0.9}]}

Transcript: I decided to pause the Android redesign until next sprint.
Output: {"actions":[{"type":"decision","title":"Pause the Android redesign until next sprint","evidence":"I decided to pause the Android redesign until next sprint","confidence":0.88}]}

Transcript:
"""
$cleanedText
"""
''';
}

/// Stricter retry when the first action response was malformed.
String actionExtractionRetryPrompt({
  required String cleanedText,
  required String previousResponse,
  required DateTime now,
}) {
  return '''
Your previous response was invalid. Return exactly one valid JSON object and no
markdown, no prose, no code fence:
{"actions":[{"type":"task|reminder|decision|follow_up","title":"...","notes":"...","due_at":"YYYY-MM-DDTHH:MM:SS","evidence":"exact substring","confidence":0.0}]}

Current local time: ${now.toIso8601String()}

Important:
- evidence must be an exact substring copied from the transcript.
- omit due_at if no date/time is present.
- return {"actions":[]} if no concrete action exists.

Transcript:
"""
$cleanedText
"""

Invalid previous response:
$previousResponse
''';
}
