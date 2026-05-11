/// Prompt shapes for the refine pipeline.
library;

/// Greedy/low-temperature structured generation is most reliable for the
/// Gemma 3 1B JSON tasks.
const double kRecordLogTemperature = 0;

/// First stage: Gemma 3 1B is strongest at transcript cleanup when it is not
/// asked to also perform entity extraction. The model must return only the
/// cleaned text in JSON so parsing can remain deterministic.
String cleanupTranscriptPrompt(String rawTranscript) {
  return '''
You are VoxSynth's local English voice-transcript editor.
Clean this transcript only. Do not extract entities in this step.

Return exactly one minified JSON object and nothing else:
{"cleaned_text":"..."}

If cleaned_text contains Markdown line breaks, encode them inside the JSON string as \\n. Do not put raw unescaped line breaks inside a JSON string.

Rules:
- Do not copy the lower-case transcript unchanged; produce polished English.
- Fix casing, punctuation, grammar, sentence boundaries, and word order.
- Correct spelling mistakes, homophones, and pronunciation-derived ASR mistakes when the intended word is clear from context.
- Fix obvious misheard words and names, e.g. "shiv knee" -> "Shivani", "doctor rao" -> "Dr. Rao", "x ray" -> "X-ray".
- Normalize obvious spoken times and numbers: "three pm" -> "3 PM", "nine thirty" -> "9:30", "six forty five" -> "6:45", "terminal too" -> "Terminal 2".
- Remove filler words such as "um" only when they add no meaning.
- Preserve every concrete detail, task, event, name, place, time, number, and relationship from the transcript.
- This is not a summarization task. Never summarize the transcript.
- Do not shorten aggressively, merge unrelated thoughts, invent details, or add reminders that are not present.
- Rewrite the whole transcript in polished English; the cleaned text must contain the same information as the input.
- Improve readability with structure when it helps: use short paragraphs for topic changes and bullet lists for explicit lists, tasks, errands, decisions, or action items.
- Use a simple Markdown table only when the transcript clearly contains repeated structured records with the same fields; otherwise prefer paragraphs or bullets.
- Formatting must not remove, compress, merge, reorder, or summarize any information.
- If a spelling or name is ambiguous, keep the closest faithful wording instead of guessing.
- Keep the output close to the original length. For long transcripts, produce a long cleaned transcript, not a summary.

Examples:
Input: um met shiv knee at cafe coffee day for project atlas around three pm need to send notes later
Output: {"cleaned_text":"I met Shivani at Cafe Coffee Day for Project Atlas around 3 PM. I need to send the notes later."}

Input: need too send teh revised deck to shiv knee before friday morning
Output: {"cleaned_text":"I need to send the revised deck to Shivani before Friday morning."}

Input: dentist appointment with doctor rao monday nine thirty remember insurance card and x ray reports
Output: {"cleaned_text":"I have a dentist appointment with Dr. Rao on Monday at 9:30. Remember the insurance card and X-ray reports."}

Input: pick up mom from the airport terminal too at six forty five flight air india one zero one
Output: {"cleaned_text":"Pick up Mom from the airport, Terminal 2, at 6:45. The flight is Air India 101."}

Input: tasks for tomorrow call doctor rao at nine thirty send project atlas notes to shivani buy milk and eggs
Output: {"cleaned_text":"Tasks for tomorrow:\\n- Call Dr. Rao at 9:30.\\n- Send Project Atlas notes to Shivani.\\n- Buy milk and eggs."}

Transcript:
"""
$rawTranscript
"""
''';
}

/// Stricter cleanup retry when the first response was not parseable JSON.
String cleanupTranscriptRetryPrompt(
  String rawTranscript,
  String previousResponse,
) {
  return '''
Your previous response was invalid. Return exactly one valid JSON object with
one key and no markdown, no prose, no code fence:
{"cleaned_text":"corrected transcript"}

Transcript:
"""
$rawTranscript
"""

Invalid previous response:
$previousResponse
''';
}

/// Retry when the model returned valid JSON but the cleanup appears to have
/// dropped too much transcript content.
String cleanupTranscriptPreservationRetryPrompt(
  String rawTranscript,
  String previousCleanedText,
) {
  return '''
Your previous cleaned transcript was too short or lost information. Rewrite it.

Return exactly one valid minified JSON object and nothing else:
{"cleaned_text":"..."}

If cleaned_text contains Markdown line breaks, encode them inside the JSON string as \\n. Do not put raw unescaped line breaks inside a JSON string.

Non-negotiable rules:
- Preserve all information from the transcript. Never summarize.
- Include every distinct thought, task, event, detail, name, place, time, and number.
- Only fix grammar, spelling, punctuation, casing, sentence boundaries, obvious speech-to-text/pronunciation mistakes, and readable formatting.
- Use paragraphs or bullet lists when helpful, but do not compress or omit details.
- Keep the cleaned text close to the original length. For a long transcript, return a long cleaned transcript.
- If unsure about a word or name, keep the faithful original wording instead of deleting it.

Transcript:
"""
$rawTranscript
"""

Previous cleaned transcript that lost content:
"""
$previousCleanedText
"""
''';
}

/// Second stage: extract entities only from already-cleaned text. This avoids
/// asking Gemma 3 1B to edit and tag at the same time, and lets Dart enforce
/// exact-substring mentions before offset recovery.
String entityExtractionPrompt(String cleanedText) {
  return '''
You are VoxSynth's local entity extractor.
Extract entities from the cleaned transcript. Do not rewrite the transcript.

Return exactly one minified JSON object and nothing else:
{"entities":[{"text":"...","type":"PERSON|PLACE|PROJECT|DURATION|TIME|NUMBER|OTHER"}]}

Rules:
- Every "text" value must be copied exactly from the cleaned transcript.
- Extract only the shortest useful entity span, not a whole action phrase.
- Extract named people, places, projects, dates/times, durations, and important numbers.
- Use PERSON for named people and close family references like Mom or Dad when they refer to a person.
- Use PLACE for venues, businesses, cities, schools, hospitals, rooms, terminals, and stores.
- Use PROJECT for named projects, apps, releases, or work initiatives.
- Use TIME for dates, days, deadlines, clock times, and relative times like tomorrow.
- Use DURATION for time spans: "30 minutes", "2 hours", "3 days", "a week".
- Use NUMBER for amounts, flight numbers, ticket numbers, invoice numbers, quantities, and IDs.
- Use OTHER only for important named things like vitamin D; avoid OTHER for generic phrases.
- Never extract verbs or action phrases such as "dentist appointment", "pick up Mom", "book cake", "send revised deck", or "meeting".
- Do not extract generic actions, pronouns, filler words, or ordinary nouns.
- If unsure, omit the entity. Include at most 12 entities.

Examples:
Cleaned transcript: I met Shivani at Cafe Coffee Day for Project Atlas around 3 PM. I need to send the notes later.
Output: {"entities":[{"text":"Shivani","type":"PERSON"},{"text":"Cafe Coffee Day","type":"PLACE"},{"text":"Project Atlas","type":"PROJECT"},{"text":"3 PM","type":"TIME"}]}

Cleaned transcript: Pay the electricity bill by Friday. The amount is 2,340.
Output: {"entities":[{"text":"Friday","type":"TIME"},{"text":"2,340","type":"NUMBER"}]}

Cleaned transcript: I have a dentist appointment with Dr. Rao on Monday at 9:30. Remember the insurance card and X-ray reports.
Output: {"entities":[{"text":"Dr. Rao","type":"PERSON"},{"text":"Monday","type":"TIME"},{"text":"9:30","type":"TIME"}]}

Cleaned transcript: Pick up Mom from the airport, Terminal 2, at 6:45. The flight is Air India 101.
Output: {"entities":[{"text":"Mom","type":"PERSON"},{"text":"airport","type":"PLACE"},{"text":"Terminal 2","type":"PLACE"},{"text":"6:45","type":"TIME"},{"text":"Air India 101","type":"NUMBER"}]}

Cleaned transcript: The meeting lasted 45 minutes. Follow up in 2 weeks.
Output: {"entities":[{"text":"45 minutes","type":"DURATION"},{"text":"2 weeks","type":"DURATION"}]}

Cleaned transcript:
"""
$cleanedText
"""
''';
}

/// Stricter entity retry when the first response was malformed or included
/// entity text that could not be located in the cleaned transcript.
String entityExtractionRetryPrompt(
  String cleanedText,
  String previousResponse,
) {
  return '''
Your previous response was invalid. Return exactly one valid JSON object and no
markdown:
{"entities":[{"text":"exact substring","type":"PERSON|PLACE|PROJECT|DURATION|TIME|NUMBER|OTHER"}]}

Important:
- Each text must be an exact substring copied from the cleaned transcript.
- If no safe entities exist, return {"entities":[]}.

Cleaned transcript:
"""
$cleanedText
"""

Invalid previous response:
$previousResponse
''';
}

/// Legacy one-shot prompt retained for standalone comparison evals. Production
/// refinement uses [cleanupTranscriptPrompt] + [entityExtractionPrompt].
String recordLogPrompt(String rawTranscript) {
  return '''
You are VoxSynth's local English transcript editor and entity extractor.
Fix grammar, casing, punctuation, spelling mistakes, and obvious
speech-to-text or pronunciation-derived errors in the voice transcript. Remove
filler words only when they add no meaning.

Return exactly one minified JSON object and nothing else:
{"cleaned_text":"...","entities":[{"text":"...","type":"PERSON|PLACE|PROJECT|DURATION|TIME|NUMBER|OTHER"}]}

Entity rules:
- "text" must be an exact substring copied from cleaned_text.
- Extract named people, places, projects, dates/times, durations, and important numbers.
- Do not extract generic words, filler words, or pronouns.
- Use [] when there are no entities. Include at most 20 entities.
- Do not include character offsets; Dart recovers offsets after parsing.

Editing rules:
- Preserve the user's meaning and first-person voice.
- Never summarize. Do not invent details or remove important content.
- Improve readability with paragraphs or bullet lists when helpful.
- Keep cleaned_text close to the transcript length.

Transcript:
"""
$rawTranscript
"""
''';
}

/// Legacy one-shot retry retained for standalone comparison evals.
String recordLogRetryPrompt(String rawTranscript, String previousResponse) {
  return '''
Your previous answer was invalid for VoxSynth. Respond with exactly one valid
JSON object, no markdown, no prose, no function call:
{"cleaned_text":"...","entities":[{"text":"...","type":"PERSON|PLACE|PROJECT|DURATION|TIME|NUMBER|OTHER"}]}

Requirements:
- cleaned_text is the corrected transcript, not a summary.
- Every entity text is an exact substring of cleaned_text.
- If unsure about entities, use "entities": [].

Transcript:
"""
$rawTranscript
"""

Invalid previous answer:
$previousResponse
''';
}
