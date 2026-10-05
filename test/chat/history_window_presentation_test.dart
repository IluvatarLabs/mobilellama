import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/chat/transcript.dart';

void main() {
  testWidgets(
    'prepending older rows preserves the visible message and pixel offset',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var start = 50;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ChatTranscript(
                scrollController: scroll,
                hasOlder: start > 0,
                onLoadOlder: () async => setState(() => start = 0),
                messages: [
                  for (var i = start; i < 100; i++)
                    TranscriptMessageView(
                      id: 'm$i',
                      role: TranscriptRole.assistant,
                      content:
                          'Message $i\n\nA paragraph with enough detail to keep this chat scrollable.',
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      scroll.jumpTo(0);
      await tester.pumpAndSettle();
      final message = find.textContaining('Message 50').first;
      final before = tester.getTopLeft(message).dy;
      await tester.tap(find.text('Load older messages'));
      await tester.pumpAndSettle();
      expect(find.text('Load older messages'), findsNothing);
      expect(find.textContaining('Message 50'), findsWidgets);
      expect(
        tester.getTopLeft(find.textContaining('Message 50').first).dy,
        closeTo(before, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
