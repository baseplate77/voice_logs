import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/ask/ask_chat_bubble.dart';
import 'package:voxsynth/features/ask/ask_chat_message.dart';
import 'package:voxsynth/features/search/hybrid_retriever.dart';

void main() {
  testWidgets('assistant bubble hides inline citations behind references', (
    tester,
  ) async {
    var opened = false;
    const message = AskChatMessage(
      id: 'assistant_1',
      role: AskChatRole.assistant,
      text: 'Atlas moved forward [L1].',
      streaming: false,
      logHits: [
        SearchHit(
          logId: 'log_1',
          fusedScore: 0.7,
          matchedVia: {MatchSource.fts},
          snippet: 'Atlas moved forward.',
        ),
      ],
    );

    await tester.pumpWidget(
      ScreenUtilInit(
        designSize: const Size(440, 956),
        builder: (_, child) => MaterialApp(home: child),
        child: Scaffold(
          body: AskChatBubble(
            message: message,
            onOpenLog: (_) => opened = true,
          ),
        ),
      ),
    );

    expect(find.text('[L1]', findRichText: true), findsNothing);
    expect(
      find.text('Atlas moved forward.', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('References (1)'), findsOneWidget);
    expect(find.text('L1'), findsOneWidget);
    expect(find.text('Sources'), findsNothing);

    await tester.tap(find.text('L1'));
    expect(opened, isTrue);
  });
}
