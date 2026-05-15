import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voxsynth/features/ask/ask_answer_view.dart';
import 'package:voxsynth/features/ask/ask_citation_parser.dart';

void main() {
  testWidgets('renders markdown structure while keeping citations tappable', (
    tester,
  ) async {
    Citation? tapped;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AskAnswerView(
            text: '''
## Answer
Atlas **launch** moved forward [L1]

- Update the investor deck [L2]

| Item | Source |
| --- | --- |
| Deck | [L1] |
''',
            onTapCitation: (citation) => tapped = citation,
          ),
        ),
      ),
    );

    expect(find.text('Answer', findRichText: true), findsOneWidget);
    expect(find.text('•'), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(find.text('[L1]'), findsWidgets);
    expect(find.text('[L2]'), findsOneWidget);

    await tester.tap(find.text('[L2]'));
    expect(tapped?.kind, CitationKind.log);
    expect(tapped?.index, 2);
  });

  testWidgets('can hide inline citations from the visible answer', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AskAnswerView(
            text: 'Atlas moved forward [L1].',
            showInlineCitations: false,
            onTapCitation: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('[L1]'), findsNothing);
    expect(
      find.text('Atlas moved forward.', findRichText: true),
      findsOneWidget,
    );
  });
}
