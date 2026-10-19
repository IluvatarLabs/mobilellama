import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobollama/chat/diagram.dart';
import 'package:webview_flutter/webview_flutter.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'bundled diagrams render in WebKit, expand, and keep source available',
    (tester) async {
      const sources = [
        'flowchart LR\n A[Question] --> B[Answer]',
        'sequenceDiagram\n User->>Model: Question\n Model-->>User: Answer',
        'classDiagram\n class Chat\n class Message\n Chat --> Message',
        'stateDiagram-v2\n [*] --> Ready\n Ready --> Complete',
        'erDiagram\n CHAT ||--o{ MESSAGE : contains',
        'pie title Messages\n "User" : 2\n "Assistant" : 2',
      ];
      for (final source in sources) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ListView(
                children: [
                  AnswerDiagram(key: ValueKey(source), source: source),
                ],
              ),
            ),
          ),
        );
        WebViewController? web;
        String status = '';
        for (var attempt = 0; attempt < 120; attempt++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(WebViewWidget).evaluate().isNotEmpty) {
            web = WebViewController.fromPlatform(
              tester
                  .widget<WebViewWidget>(find.byType(WebViewWidget))
                  .platform
                  .params
                  .controller,
            );
            try {
              status =
                  '${await web.runJavaScriptReturningResult('window.diagramStatus')}';
            } catch (_) {}
            if (status.contains('complete') || status.contains('failed')) break;
          }
        }
        expect(status, contains('complete'), reason: source);
        expect(
          (await web!.runJavaScriptReturningResult(
            'document.querySelectorAll("#diagram svg").length',
          ) as num).toInt(),
          1,
        );
        await tester.tap(find.text('Source'));
        await tester.pump();
        expect(find.text(source), findsOneWidget);
        await tester.tap(find.text('Source'));
        await tester.pump();
      }
      await tester.tap(find.byTooltip('Expand diagram'));
      await tester.pumpAndSettle();
      expect(find.byType(AnswerDiagram), findsWidgets);
      await tester.pageBack();
      await tester.pumpAndSettle();
      // Malformed supported syntax must leave a useful source fallback.
      const invalid = 'flowchart LR\n A[unterminated';
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AnswerDiagram(key: ValueKey('invalid'), source: invalid),
          ),
        ),
      );
      for (
        var i = 0;
        i < 120 &&
            find.textContaining('Preview unavailable').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text(invalid), findsOneWidget);
      expect(find.textContaining('Preview unavailable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
