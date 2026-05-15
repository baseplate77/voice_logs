/// Prompt shapes for the daily / weekly digest stage.
library;

/// Greedy decoding so JSON shape is stable. Matches the rest of the refine
/// pipeline for Gemma 3 1B structured-output tasks.
const double kDigestTemperature = 0;

/// One log fed into a digest prompt. We keep this struct tiny — title and
/// body text — so the runner can budget characters across many logs
/// without dragging in row IDs or processing state.
class DigestLogInput {
  const DigestLogInput({
    required this.createdAt,
    required this.title,
    required this.body,
  });

  final DateTime createdAt;
  final String title;
  final String body;
}

/// Primary daily-digest prompt. Asks for a single minified JSON object
/// covering one-liner, what-happened bullets, people, tasks, decisions,
/// and mood/theme. Every list may be empty; only `one_liner` is required.
String dailyDigestPrompt({
  required String dateLabel,
  required List<DigestLogInput> logs,
}) {
  return '''
You are VoxSynth's local journal digest writer.
Read the voice logs from $dateLabel below and produce a structured daily digest.

Return exactly one minified JSON object and nothing else:
{"one_liner":"...","what_happened":["...","...","..."],"people_mentioned":["..."],"tasks_created":["..."],"decisions":["..."],"mood_theme":"..."}

If any string contains Markdown line breaks, encode them inside the JSON string as \\n. Do not put raw unescaped line breaks inside a JSON string.

Rules:
- one_liner: one short sentence (max ~140 chars) summarizing the day.
- what_happened: 3-5 short factual bullets covering the most important moments of the day. Plain sentences, no leading dashes or bullets.
- people_mentioned: distinct named people, projects, products, or organizations actually mentioned across the day. Use the exact spelling from the logs. No pronouns.
- tasks_created: action items, tasks, reminders, or "things to do later" stated across the day. Empty array if none.
- decisions: concrete decisions made or conclusions reached across the day. Empty array if none.
- mood_theme: one short phrase capturing the day's overall mood or theme (e.g. "focused on shipping", "stressed about timelines", "social and upbeat"). Empty string if unclear.
- Never invent details that are not in the logs. If a field has nothing to say, return an empty array (or empty string for mood_theme).
- Use plain English. Do not include timestamps, speaker tags, or transcript filler.

${_formatLogs(logs)}
''';
}

/// Stricter retry for parse failures on the daily digest.
String dailyDigestRetryPrompt({
  required String dateLabel,
  required List<DigestLogInput> logs,
  required String previousResponse,
}) {
  return '''
Your previous response was invalid. Return exactly one valid minified JSON object with these six keys and no markdown, no prose, no code fence:
{"one_liner":"...","what_happened":["..."],"people_mentioned":["..."],"tasks_created":["..."],"decisions":["..."],"mood_theme":"..."}

Every list must be a JSON array of strings (empty array allowed). one_liner and mood_theme must be single strings. mood_theme may be the empty string.

Logs from $dateLabel:
${_formatLogs(logs)}

Invalid previous response:
$previousResponse
''';
}

/// Primary weekly-digest prompt. Asks for a single minified JSON object
/// covering one-liner, main themes, project progress, repeated concerns,
/// and unfinished tasks.
String weeklyDigestPrompt({
  required String windowLabel,
  required List<DigestLogInput> logs,
}) {
  return '''
You are VoxSynth's local journal digest writer.
Read the voice logs from $windowLabel below and produce a structured weekly review.

Return exactly one minified JSON object and nothing else:
{"one_liner":"...","main_themes":["..."],"project_progress":["..."],"repeated_concerns":["..."],"unfinished_tasks":["..."]}

If any string contains Markdown line breaks, encode them inside the JSON string as \\n. Do not put raw unescaped line breaks inside a JSON string.

Rules:
- one_liner: one short sentence (max ~140 chars) summarizing the week.
- main_themes: 3-5 short phrases capturing the dominant themes that ran through the week.
- project_progress: progress notes on specific projects or initiatives mentioned across the week. Empty array if none.
- repeated_concerns: worries, blockers, or topics the user came back to more than once across the week. Empty array if none.
- unfinished_tasks: tasks, follow-ups, or commitments mentioned across the week that do not have a clear resolution by week's end. Empty array if none.
- Never invent details that are not in the logs. If a field has nothing to say, return an empty array.
- Use plain English. Do not include timestamps, speaker tags, or transcript filler.

${_formatLogs(logs)}
''';
}

/// Stricter retry for parse failures on the weekly digest.
String weeklyDigestRetryPrompt({
  required String windowLabel,
  required List<DigestLogInput> logs,
  required String previousResponse,
}) {
  return '''
Your previous response was invalid. Return exactly one valid minified JSON object with these five keys and no markdown, no prose, no code fence:
{"one_liner":"...","main_themes":["..."],"project_progress":["..."],"repeated_concerns":["..."],"unfinished_tasks":["..."]}

Every list must be a JSON array of strings (empty array allowed). one_liner must be a single string.

Logs from $windowLabel:
${_formatLogs(logs)}

Invalid previous response:
$previousResponse
''';
}

String _formatLogs(List<DigestLogInput> logs) {
  if (logs.isEmpty) return 'Logs:\n(no logs)';
  final buffer = StringBuffer('Logs:\n');
  for (var i = 0; i < logs.length; i++) {
    final log = logs[i];
    final stamp = _formatStamp(log.createdAt);
    final title = log.title.trim().isEmpty ? 'Untitled log' : log.title.trim();
    buffer
      ..writeln('--- Log ${i + 1} ($stamp) — $title ---')
      ..writeln(log.body.trim())
      ..writeln();
  }
  return buffer.toString();
}

String _formatStamp(DateTime t) {
  final y = t.year.toString().padLeft(4, '0');
  final mo = t.month.toString().padLeft(2, '0');
  final d = t.day.toString().padLeft(2, '0');
  final h = t.hour.toString().padLeft(2, '0');
  final mi = t.minute.toString().padLeft(2, '0');
  return '$y-$mo-$d $h:$mi';
}
