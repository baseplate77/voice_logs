import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/core/db/repositories/entity_mention_repository.dart';
import 'package:voxsynth/features/detail/markdown_transcript_view.dart';

void main() {
  testWidgets('renders markdown bullets and tables', (tester) async {
    const text = '''Tasks:
- Call Dr. Rao at 9:30.
- Send Project Atlas notes to Shivani.

| Item | Time |
| --- | --- |
| Pickup | 6:45 |
''';

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(440, 956),
        builder: (_, child) => MaterialApp(home: child),
        child: const Scaffold(
          body: MarkdownTranscriptView(
            text: text,
            mentions: [
              EntityMentionView(
                id: 'm1',
                logId: 'log_1',
                text: 'Shivani',
                type: 'PERSON',
                charStart: 65,
                charEnd: 72,
                canonicalEntityId: null,
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Tasks:'), findsOneWidget);
    expect(find.text('•'), findsNWidgets(2));
    expect(find.textContaining('Call Dr. Rao'), findsOneWidget);
    expect(find.textContaining('Send Project Atlas'), findsOneWidget);
    expect(find.text('Item'), findsOneWidget);
    expect(find.text('Pickup'), findsOneWidget);
  });
}
