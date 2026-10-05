import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobollama/chat/attachment_strip.dart';
import 'package:mobollama/chat/chat_screen.dart';
import 'package:mobollama/chat/composer.dart';
import 'package:mobollama/chat/find_in_chat.dart';
import 'package:mobollama/chat/queue_panel.dart';
import 'package:mobollama/chat/transcript.dart';
import 'package:mobollama/domain/queued_prompt.dart';

import '../support/chat_fixture.dart';

void main() {
  testWidgets(
    'header names each chat destination and a failed revision restores from its answer',
    (tester) async {
      final fixture = ChatFixture();
      await tester.runAsync(() async {
        await fixture.open();
        await fixture.seed('home-chat', content: 'Original answer');
        await fixture.seed('lab-chat', profile: 'lab');
        await fixture.controller.initialize();
        await fixture.controller.openConversation('lab-chat');
      });
      await tester.pumpWidget(
        MaterialApp(home: ChatScreen(controller: fixture.controller)),
      );
      await tester.pump();
      expect(find.text('Lab · Ready'), findsOneWidget);

      await tester.runAsync(() async {
        await fixture.controller.openConversation('home-chat');
        fixture.failNextResponses = 1;
        await fixture.controller.regenerateAssistant('home-chat-assistant');
      });
      await tester.pump();
      expect(find.text('Lab · Ready'), findsNothing);
      expect(find.textContaining('Home · '), findsOneWidget);
      expect(find.text('Original answer'), findsNothing);
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      await tester.ensureVisible(find.byTooltip('Previous version'));
      await tester.tap(find.byTooltip('Previous version'));
      // Restore runs real database work; let it finish between frames.
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(find.text('Original answer'), findsOneWidget);
      await tester.tap(find.text('Continue from this version'));
      for (var i = 0; i < 5; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      expect(fixture.controller.viewingAlternative, isFalse);
      expect(fixture.controller.hasRecoveryCheckpoint('home-chat'), isFalse);
      await tester.pumpWidget(const SizedBox());
      // Shutdown mixes fake-zone draft writes with real database work.
      var closed = false;
      unawaited(fixture.close().whenComplete(() => closed = true));
      for (var i = 0; i < 50 && !closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(closed, isTrue);
    },
  );

  testWidgets('streaming keeps Stop separate from the queued send action', (
    tester,
  ) async {
    final sent = <String>[];
    var stops = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            isStreaming: true,
            onSend: (text) async {
              sent.add(text);
              return true;
            },
            onStop: () => stops += 1,
          ),
        ),
      ),
    );

    expect(find.byTooltip('Stop response'), findsOneWidget);
    expect(find.byTooltip('Queue message'), findsNothing);
    await tester.enterText(find.byType(TextField), 'follow up');
    await tester.pump();
    expect(find.byTooltip('Stop response'), findsOneWidget);
    expect(find.byTooltip('Queue message'), findsOneWidget);

    await tester.tap(find.byTooltip('Queue message'));
    await tester.pump();
    expect(sent, <String>['follow up']);
    expect(stops, 0);
    expect(find.byTooltip('Stop response'), findsOneWidget);

    await tester.tap(find.byTooltip('Stop response'));
    expect(stops, 1);
  });

  testWidgets(
    'short landscape with keyboard and largest text keeps Stop and Queue tappable',
    (tester) async {
      // iPhone SE landscape with the keyboard up, AX5-sized text.
      tester.view.physicalSize = const Size(667, 375);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 209);
      addTearDown(tester.view.reset);
      final sent = <String>[];
      var stops = 0;
      final draft = List<String>.generate(40, (i) => 'Line $i').join('\n');

      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(3.1)),
            child: child!,
          ),
          home: Scaffold(
            appBar: AppBar(toolbarHeight: 52, title: const Text('Chat')),
            body: Column(
              children: <Widget>[
                const Expanded(child: SizedBox.expand()),
                Flexible(
                  child: ChatComposer(
                    compact: true,
                    isStreaming: true,
                    draftText: draft,
                    onSend: (text) async {
                      sent.add(text);
                      return true;
                    },
                    onStop: () => stops += 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), draft);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final body = tester.getRect(find.byType(Column).first);
      for (final label in <String>['Stop response', 'Queue message']) {
        final rect = tester.getRect(find.byTooltip(label));
        expect(rect.shortestSide, greaterThanOrEqualTo(44));
        expect(rect.bottom, lessThanOrEqualTo(body.bottom));
      }
      await tester.tap(find.byTooltip('Stop response'));
      await tester.tap(find.byTooltip('Queue message'));
      await tester.pump();
      expect(stops, 1);
      expect(sent, <String>[draft]);
    },
  );

  testWidgets('a paused queue labels a new draft as Queue', (tester) async {
    final sent = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            isQueueing: true,
            draftText: 'another follow up',
            onSend: (text) async {
              sent.add(text);
              return true;
            },
            onStop: () {},
          ),
        ),
      ),
    );

    expect(find.byTooltip('Queue message'), findsOneWidget);
    expect(find.byTooltip('Send'), findsNothing);
    expect(find.byTooltip('Stop response'), findsNothing);
    await tester.tap(find.byTooltip('Queue message'));
    await tester.pump();
    expect(sent, <String>['another follow up']);
  });

  testWidgets(
    'queue edit remove reorder use stable IDs and Resume does not lock rows',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final resume = Completer<void>();
      final edits = <(String, String)>[];
      final removed = <String>[];
      final orders = <List<String>>[];
      final prompts = <QueuedPrompt>[
        _prompt('first', 'A long first queued message that wraps cleanly'),
        _prompt('second', 'Second queued message'),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(390, 844),
              devicePixelRatio: 1,
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: QueuedPromptPanel(
                prompts: prompts,
                paused: true,
                onResume: () => resume.future,
                onEdit: (id, text) async => edits.add((id, text)),
                onRemove: (id) async => removed.add(id),
                onReorder: (ids) async => orders.add(ids),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Queued (2)'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Resume'));
      await tester.pump();
      await tester.tap(find.byTooltip('Edit queued message').first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'A long first queued message that wraps cleanly',
      );
      await tester.enterText(find.byType(TextField), 'revised first');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(edits, <(String, String)>[('first', 'revised first')]);
      resume.complete();
      await tester.pump();

      final handles = find.byIcon(Icons.drag_handle_rounded);
      expect(handles.hitTestable(), findsNWidgets(2));
      expect(
        tester
            .widgetList<ReorderableDragStartListener>(
              find.byType(ReorderableDragStartListener),
            )
            .every((listener) => listener.enabled),
        isTrue,
      );
      final start = tester.getCenter(handles.at(1));
      final target = tester.getCenter(handles.at(0));
      await tester.timedDrag(
        handles.at(1),
        Offset(0, target.dy - start.dy - 30),
        const Duration(seconds: 1),
      );
      await tester.pumpAndSettle();
      expect(orders, <List<String>>[
        <String>['second', 'first'],
      ]);

      await tester.tap(find.byTooltip('Remove queued message').first);
      await tester.pump();
      expect(removed, <String>['second']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('pending image controls remove the selected reference', (
    tester,
  ) async {
    final removed = <String?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PendingImageStrip(
            references: const <String>['/tmp/one.png', '/tmp/two.png'],
            onRemove: ([reference]) async => removed.add(reference),
          ),
        ),
      ),
    );

    expect(find.byTooltip('Remove image 1'), findsOneWidget);
    expect(find.byTooltip('Remove image 2'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove image 2'));
    await tester.pump();
    expect(removed, <String?>['/tmp/two.png']);
  });

  testWidgets('sent image opens a contained interactive viewer', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'image-message',
                role: TranscriptRole.user,
                content: '',
                imageReferences: <String>['/tmp/missing.png'],
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final attachedImage = find.byWidgetPredicate(
      (widget) =>
          widget is Semantics &&
          widget.properties.label == 'Open attached image',
    );
    await tester.tap(attachedImage);
    await tester.pumpAndSettle();
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(find.byTooltip('Close image'), findsOneWidget);
  });

  testWidgets('Find reveals matches within and beyond a multi-screen message', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = ChatFindController();
    addTearDown(controller.dispose);
    final lines = <String>[
      'needle near the beginning',
      ...List<String>.generate(130, (index) => 'filler line $index'),
      'needle deep in the same answer',
    ];
    final longMessage = lines.join('\n');
    final messages = <TranscriptMessageView>[
      TranscriptMessageView(
        id: 'long',
        role: TranscriptRole.assistant,
        content: longMessage,
      ),
      ...List<TranscriptMessageView>.generate(
        12,
        (index) => TranscriptMessageView(
          id: 'filler-$index',
          role: TranscriptRole.user,
          content: 'Other message $index',
        ),
      ),
      const TranscriptMessageView(
        id: 'last',
        role: TranscriptRole.assistant,
        content: 'needle in an offscreen message',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Column(
              children: <Widget>[
                if (controller.isOpen) ChatFindBar(controller: controller),
                Expanded(
                  child: ChatTranscript(
                    key: const PageStorageKey<String>('transcript-test-chat'),
                    messages: messages,
                    findController: controller,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final transcriptController = tester
        .widget<ListView>(find.byType(ListView))
        .controller!;
    final initialPosition = transcriptController.position;
    expect(initialPosition.pixels, greaterThan(0));
    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final savedOffset = tester
        .widget<ListView>(find.byType(ListView))
        .controller!
        .position
        .pixels;
    expect(savedOffset, greaterThan(0));
    expect(savedOffset, lessThan(initialPosition.maxScrollExtent));

    controller.open();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).controller,
      same(transcriptController),
    );
    controller.setQuery('needle');
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);
    _expectActiveMatchVisible(tester, controller, longMessage);

    controller.next();
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    expect(controller.activeMatch!.itemIndex, 0);
    _expectActiveMatchVisible(tester, controller, longMessage);

    controller.next();
    await tester.pumpAndSettle();
    expect(find.text('3/3'), findsOneWidget);
    expect(controller.activeMatch!.itemIndex, messages.length - 1);
    _expectActiveMatchVisible(tester, controller, messages.last.content);

    await tester.tap(find.byTooltip('Close find'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).controller,
      same(transcriptController),
    );
    expect(transcriptController.offset, greaterThanOrEqualTo(0));
    expect(
      transcriptController.offset,
      lessThanOrEqualTo(transcriptController.position.maxScrollExtent),
    );

    controller.open();
    await tester.pumpAndSettle();
    expect(
      tester.widget<ListView>(find.byType(ListView)).controller,
      same(transcriptController),
    );
    expect(find.text('3/3'), findsOneWidget);
    controller.previous();
    await tester.pumpAndSettle();
    expect(find.text('2/3'), findsOneWidget);
    _expectActiveMatchVisible(tester, controller, longMessage);
    expect(tester.takeException(), isNull);
  });

  testWidgets('code stays exact while syntax and math render independently', (
    tester,
  ) async {
    Map<Object?, Object?>? clipboardPayload;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardPayload = Map<Object?, Object?>.from(
              call.arguments as Map,
            );
          }
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
    const source = r'''Equation: $x^2 + y^2 = z^2$.

```dart
const price = r'$5';
```
''';

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'rendered',
                role: TranscriptRole.assistant,
                content: source,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Math), findsOneWidget);
    final code = tester
        .widgetList<SelectableText>(find.byType(SelectableText))
        .singleWhere(
          (widget) =>
              widget.textSpan?.toPlainText().contains('const price') ?? false,
        );
    expect(code.textSpan!.toPlainText(), "const price = r'\$5';\n");
    expect(code.textSpan!.children, isNotEmpty);
    await tester.tap(find.byTooltip('Copy code'));
    await tester.pump();
    expect(clipboardPayload, <Object?, Object?>{
      'text': "const price = r'\$5';\n",
    });

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'partial',
                role: TranscriptRole.assistant,
                status: TranscriptStatus.streaming,
                content: r'Partial math: $\frac{$',
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

QueuedPrompt _prompt(String id, String text) => QueuedPrompt(
  id: id,
  conversationId: 'chat',
  text: text,
  imageReferences: const <String>[],
  documents: const [],
  createdAt: DateTime(2026),
);

void _expectActiveMatchVisible(
  WidgetTester tester,
  ChatFindController controller,
  String text,
) {
  final match = controller.activeMatch!;
  final richText = find.byWidgetPredicate(
    (widget) => widget is RichText && widget.text.toPlainText() == text,
  );
  final paragraph = tester.renderObject<RenderParagraph>(richText);
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: match.start, extentOffset: match.end),
  );
  expect(boxes, isNotEmpty);
  final global = MatrixUtils.transformRect(
    paragraph.getTransformTo(null),
    boxes.first.toRect(),
  );
  final transcript = tester.getRect(find.byType(ChatTranscript));
  expect(global.top, greaterThanOrEqualTo(transcript.top));
  expect(global.bottom, lessThanOrEqualTo(transcript.bottom));
}
