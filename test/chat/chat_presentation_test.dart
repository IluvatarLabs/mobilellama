import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mobollama/chat/activity_disclosure.dart';
import 'package:mobollama/chat/composer.dart';
import 'package:mobollama/chat/speech_actions.dart';
import 'package:mobollama/chat/transcript.dart';
import 'package:mobollama/domain/document_attachment.dart';

void main() {
  testWidgets('composer routes image, send, and stop states', (tester) async {
    final key = GlobalKey<_ComposerHarnessState>();
    await tester.pumpWidget(MaterialApp(home: _ComposerHarness(key: key)));

    expect(
      tester.getSize(find.byTooltip('Add attachment')).shortestSide,
      greaterThanOrEqualTo(44),
    );
    expect(
      tester.getSize(find.byTooltip('Send')).shortestSide,
      greaterThanOrEqualTo(44),
    );

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Photo library'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  hello locally  ');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();

    expect(key.currentState!.imagePicks, 1);
    expect(key.currentState!.sent, <String>['hello locally']);
    expect(find.text('hello locally'), findsNothing);
    expect(find.byTooltip('Stop response'), findsOneWidget);
    expect(
      tester.getSize(find.byTooltip('Stop response')).shortestSide,
      greaterThanOrEqualTo(44),
    );

    await tester.enterText(find.byType(TextField), 'A follow-up draft');
    await tester.pump();
    expect(find.text('A follow-up draft'), findsOneWidget);
    expect(find.byTooltip('Queue message'), findsOneWidget);
    await tester.tap(find.byTooltip('Stop response'));
    await tester.pump();
    expect(key.currentState!.stops, 1);
    expect(find.text('A follow-up draft'), findsOneWidget);
    expect(find.byTooltip('Send'), findsOneWidget);
  });

  testWidgets('composer sends attachments without inventing a caption', (
    tester,
  ) async {
    final sent = <String>[];
    final dictation = _FakeDictationEngine();

    Widget subject({required bool hasAttachments}) => MaterialApp(
      home: Scaffold(
        body: ChatComposer(
          hasAttachments: hasAttachments,
          dictationEngine: dictation,
          onSend: (text) async {
            sent.add(text);
            return true;
          },
          onStop: () {},
        ),
      ),
    );

    await tester.pumpWidget(subject(hasAttachments: true));
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(sent, <String>['']);

    await tester.pumpWidget(subject(hasAttachments: false));
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    await tester.pump();
    expect(sent, <String>['']);
  });

  testWidgets('streaming answer exposes stable actions only after completion', (
    tester,
  ) async {
    Widget subject(TranscriptStatus status) => MaterialApp(
      home: Scaffold(
        body: ChatTranscript(
          messages: <TranscriptMessageView>[
            TranscriptMessageView(
              id: 'answer',
              role: TranscriptRole.assistant,
              content: 'A useful answer in progress',
              status: status,
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(subject(TranscriptStatus.streaming));
    expect(find.byTooltip('Copy response'), findsOneWidget);
    expect(find.byTooltip('Response actions'), findsNothing);

    await tester.pumpWidget(subject(TranscriptStatus.completed));
    await tester.pump();
    expect(find.byTooltip('Copy response'), findsOneWidget);
    await _openMenu(tester, 'Response actions');
    expect(find.text('Read aloud'), findsOneWidget);
    expect(find.text('Share'), findsOneWidget);
  });

  testWidgets('transcript keeps activity secondary; More copies both roles', (
    tester,
  ) async {
    String? copied;
    String? retried;
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

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            onCopy: (value) => copied = value,
            onRetry: (message) => retried = message.id,
            messages: const <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'user',
                role: TranscriptRole.user,
                content: 'Question',
              ),
              TranscriptMessageView(
                id: 'assistant',
                role: TranscriptRole.assistant,
                status: TranscriptStatus.failed,
                canRetry: true,
                content: '**Answer**',
                thinking: 'Reasoning detail',
                toolCalls: <ToolActivityView>[
                  ToolActivityView(
                    label: 'Search local files',
                    detail: 'Found one match',
                  ),
                ],
              ),
              TranscriptMessageView(
                id: 'system',
                role: TranscriptRole.system,
                content: 'Connection restored',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Activity'), findsOneWidget);
    expect(find.text('Reasoning detail').hitTestable(), findsNothing);
    expect(
      tester.getSize(find.widgetWithText(TextButton, 'Activity')).height,
      greaterThanOrEqualTo(44),
    );

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Reasoning detail').hitTestable(), findsOneWidget);
    expect(find.text('Found one match').hitTestable(), findsOneWidget);

    await _openMenu(tester, 'Message actions');
    await tester.tap(find.text('Copy message'));
    await tester.pumpAndSettle();
    expect(clipboardPayload, <Object?, Object?>{'text': 'Question'});
    expect(find.text('Message copied.'), findsOneWidget);

    await _openMenu(tester, 'Response actions');
    await tester.tap(find.text('Copy response'));
    await tester.pumpAndSettle();
    expect(copied, '**Answer**');
    expect(clipboardPayload, <Object?, Object?>{'text': '**Answer**'});

    await tester.tap(find.text('Retry'));
    expect(retried, 'assistant');
  });

  testWidgets('edit cancel preserves original and save resends exact message', (
    tester,
  ) async {
    final edits = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: const <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'user-17',
                role: TranscriptRole.user,
                content: 'Original question',
                canEdit: true,
                editRemovesLaterMessages: true,
              ),
            ],
            onEditAndResend: (message, text) async {
              edits.add((message.id, text));
              return true;
            },
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byTooltip('Message actions')).shortestSide,
      greaterThanOrEqualTo(44),
    );
    await _openEdit(tester);
    var field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('edit-message-field')),
    );
    expect(field.controller!.text, 'Original question');
    expect(
      find.text('This replaces this message and removes every reply after it.'),
      findsOneWidget,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-message-field')),
      'Changed but cancelled',
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(edits, isEmpty);

    await _openEdit(tester);
    field = tester.widget<TextField>(
      find.byKey(const ValueKey<String>('edit-message-field')),
    );
    expect(field.controller!.text, 'Original question');
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-message-field')),
      '   ',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save & resend'));
    await tester.pump();
    expect(find.text('Enter a message.'), findsOneWidget);
    expect(edits, isEmpty);
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-message-field')),
      '  Revised question  ',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save & resend'));
    await tester.pumpAndSettle();

    expect(edits, <(String, String)>[('user-17', 'Revised question')]);
  });

  testWidgets('edit can resend retained attachments with an empty caption', (
    tester,
  ) async {
    final edits = <(String, String)>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: const <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'attachment-message',
                role: TranscriptRole.user,
                content: 'Remove this caption',
                canEdit: true,
                documents: <DocumentAttachment>[
                  DocumentAttachment(
                    id: 'document',
                    name: 'notes.md',
                    mimeType: 'text/markdown',
                    reference: '/tmp/notes.md',
                    text: 'Attached notes',
                  ),
                ],
              ),
            ],
            onEditAndResend: (message, text) async {
              edits.add((message.id, text));
              return true;
            },
          ),
        ),
      ),
    );

    await _openEdit(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-message-field')),
      '',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save & resend'));
    await tester.pumpAndSettle();

    expect(edits, <(String, String)>[('attachment-message', '')]);
  });

  testWidgets('edit rechecks the live mutation guard after its sheet closes', (
    tester,
  ) async {
    var mutationAllowed = true;
    var editCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            canMutate: () => mutationAllowed,
            messages: const <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'user',
                role: TranscriptRole.user,
                content: 'Original',
                canEdit: true,
              ),
            ],
            onEditAndResend: (_, _) async {
              editCalls += 1;
              return true;
            },
          ),
        ),
      ),
    );

    await _openEdit(tester);
    await tester.enterText(
      find.byKey(const ValueKey<String>('edit-message-field')),
      'Changed',
    );
    mutationAllowed = false;
    await tester.tap(find.widgetWithText(FilledButton, 'Save & resend'));
    await tester.pumpAndSettle();

    expect(editCalls, 0);
    expect(find.text('Wait for the current action to finish.'), findsOneWidget);
  });

  testWidgets('older interrupted response confirms before regeneration', (
    tester,
  ) async {
    final regenerated = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: const <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'assistant-old',
                role: TranscriptRole.assistant,
                status: TranscriptStatus.interrupted,
                content: 'Earlier answer',
                canRegenerate: true,
                regenerateRemovesLaterMessages: true,
              ),
            ],
            onRegenerate: (message) async {
              regenerated.add(message.id);
              return true;
            },
          ),
        ),
      ),
    );

    expect(find.text('Interrupted'), findsOneWidget);
    await _openMenu(tester, 'Response actions');
    await tester.tap(find.text('Regenerate'));
    await tester.pumpAndSettle();
    expect(
      find.text('This response and every message after it will be removed.'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(regenerated, isEmpty);

    await _openMenu(tester, 'Response actions');
    await tester.tap(find.text('Regenerate'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Regenerate'));
    await tester.pumpAndSettle();
    expect(regenerated, <String>['assistant-old']);
  });

  testWidgets('edit and regenerate disable while mutations are blocked', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            canMutate: () => false,
            onRetry: (_) {},
            onEditAndResend: (_, _) async => true,
            onRegenerate: (_) async => true,
            messages: const <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'user',
                role: TranscriptRole.user,
                content: 'Question',
                canEdit: true,
              ),
              TranscriptMessageView(
                id: 'assistant',
                role: TranscriptRole.assistant,
                content: 'Answer',
                canRegenerate: true,
              ),
              TranscriptMessageView(
                id: 'assistant-incomplete',
                role: TranscriptRole.assistant,
                status: TranscriptStatus.interrupted,
                content: 'Partial answer',
                canRetry: true,
              ),
            ],
          ),
        ),
      ),
    );

    await _openMenu(tester, 'Message actions');
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Edit and resend'))
          .enabled,
      isFalse,
    );
    await tester.tap(find.byTooltip('Close message actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Response actions').first);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Regenerate'))
          .enabled,
      isFalse,
    );
    await tester.tap(find.byTooltip('Close response actions'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Retry'))
          .onPressed,
      isNull,
    );
  });

  testWidgets(
    'edit sheet keeps actions reachable with large text and keyboard',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
            child: Scaffold(
              body: ChatTranscript(
                onEditAndResend: (_, _) async => true,
                messages: <TranscriptMessageView>[
                  TranscriptMessageView(
                    id: 'long-user',
                    role: TranscriptRole.user,
                    content: List<String>.filled(80, 'Long message').join(' '),
                    canEdit: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byTooltip('Message actions'));
      await tester.pumpAndSettle();
      await _openEdit(tester);
      await tester.ensureVisible(
        find.widgetWithText(FilledButton, 'Save & resend'),
      );
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(FilledButton, 'Save & resend').hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'transcript follows nearby updates but respects reading position',
    (tester) async {
      final scrollController = ScrollController();
      addTearDown(scrollController.dispose);
      final key = GlobalKey<_TranscriptHarnessState>();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: _TranscriptHarness(
                key: key,
                scrollController: scrollController,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        scrollController.offset,
        moreOrLessEquals(scrollController.position.maxScrollExtent),
      );

      key.currentState!.append('followed');
      await tester.pumpAndSettle();
      expect(
        scrollController.offset,
        moreOrLessEquals(scrollController.position.maxScrollExtent),
      );

      await tester.drag(find.byType(ListView), const Offset(0, 260));
      await tester.pumpAndSettle();
      final readingOffset = scrollController.offset;
      expect(
        scrollController.position.maxScrollExtent - readingOffset,
        greaterThan(96),
      );

      key.currentState!.append('not followed');
      await tester.pumpAndSettle();
      expect(scrollController.offset, moreOrLessEquals(readingOffset));
      await tester.tap(find.byTooltip('Jump to latest'));
      await tester.pumpAndSettle();
      expect(
        scrollController.offset,
        moreOrLessEquals(scrollController.position.maxScrollExtent),
      );
    },
  );

  testWidgets(
    'dictation replaces partials and ignores manual and cross-chat late results',
    (tester) async {
      final speech = _FakeDictationEngine();
      var scope = 0;
      var draft = 'Existing draft';

      Future<void> pumpComposer() => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ChatComposer(
                dictationEngine: speech,
                draftScopeRevision: scope,
                draftText: draft,
                onDraftChanged: (value) => draft = value,
                onSend: (_) async => true,
                onStop: () {},
              ),
            ),
          ),
        ),
      );

      await pumpComposer();
      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      speech.emit('one', isFinal: false);
      await tester.pump();
      expect(find.text('Existing draft one'), findsOneWidget);
      speech.emit('one two', isFinal: false);
      await tester.pump();
      expect(find.text('Existing draft one two'), findsOneWidget);
      expect(find.text('Listening…'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Manual correction');
      await tester.pump();
      expect(speech.cancels, 1);
      speech.emit('late overwrite', isFinal: true);
      await tester.pump();
      expect(find.text('Manual correction'), findsOneWidget);

      await tester.tap(find.byTooltip('Dictate message'));
      await tester.pump();
      scope += 1;
      draft = 'Other chat draft';
      await pumpComposer();
      speech.emit('wrong chat', isFinal: true);
      await tester.pump();
      expect(find.text('Other chat draft'), findsOneWidget);
      expect(find.textContaining('wrong chat'), findsNothing);
    },
  );

  testWidgets('dictation does not revive after ending during startup', (
    tester,
  ) async {
    final speech = _FakeDictationEngine()..finishDuringStart = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            dictationEngine: speech,
            onSend: (_) async => true,
            onStop: () {},
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    expect(find.byTooltip('Dictate message'), findsOneWidget);
    expect(find.text('Listening…'), findsNothing);
  });

  testWidgets('backgrounding cancels dictation while startup is pending', (
    tester,
  ) async {
    final started = Completer<bool>();
    final speech = _FakeDictationEngine()..pendingStart = started.future;
    var draft = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatComposer(
            dictationEngine: speech,
            onDraftChanged: (value) => draft = value,
            onSend: (_) async => true,
            onStop: () {},
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    started.complete(true);
    await tester.pump();
    speech.emit('Late background recognition', isFinal: true);
    await tester.pump();
    expect(speech.cancels, greaterThan(0));
    expect(draft, isEmpty);
    expect(find.text('Listening…'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('attachment menu keeps documents available without vision', (
    tester,
  ) async {
    var photoPicks = 0;
    var documentPicks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: ChatComposer(
              imagesEnabled: false,
              onPickImage: () => photoPicks += 1,
              onTakePhoto: () => photoPicks += 1,
              onPickDocument: () => documentPicks += 1,
              onSend: (_) async => true,
              onStop: () {},
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Add attachment'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an image-capable model first.'), findsNWidgets(2));
    expect(
      tester
          .widget<ListTile>(find.widgetWithText(ListTile, 'Photo library'))
          .enabled,
      isFalse,
    );
    await tester.tap(find.text('Document'));
    await tester.pumpAndSettle();
    expect(photoPicks, 0);
    expect(documentPicks, 1);
  });

  testWidgets(
    'attachment menu scrolls at large text without clipping actions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var documentPicks = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: ChatComposer(
                  imagesEnabled: false,
                  onPickImage: () {},
                  onTakePhoto: () {},
                  onPickDocument: () => documentPicks += 1,
                  onSend: (_) async => true,
                  onStop: () {},
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.byTooltip('Add attachment'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Document'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Document'));
      await tester.pumpAndSettle();
      expect(documentPicks, 1);
    },
  );

  testWidgets('document chips open a readable extracted-text preview', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatTranscript(
            messages: const <TranscriptMessageView>[
              TranscriptMessageView(
                id: 'document-message',
                role: TranscriptRole.user,
                content: 'Review this file.',
                documents: <DocumentAttachment>[
                  DocumentAttachment(
                    id: 'document-1',
                    name: 'notes.md',
                    mimeType: 'text/markdown',
                    reference: '/tmp/notes.md',
                    text: 'Extracted document text',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.widgetWithText(OutlinedButton, 'notes.md')).height,
      greaterThanOrEqualTo(44),
    );
    await tester.tap(find.text('notes.md'));
    await tester.pumpAndSettle();
    expect(find.text('Extracted document text'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Share original'), findsOneWidget);
  });

  testWidgets(
    'read aloud stops the prior answer and ignores its late callback',
    (tester) async {
      final speaker = _FakeAnswerSpeaker();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChatTranscript(
              answerSpeaker: speaker,
              messages: const <TranscriptMessageView>[
                TranscriptMessageView(
                  id: 'answer-1',
                  role: TranscriptRole.assistant,
                  content: 'First answer',
                ),
                TranscriptMessageView(
                  id: 'answer-2',
                  role: TranscriptRole.assistant,
                  content: 'Second answer',
                ),
              ],
            ),
          ),
        ),
      );

      final stopReading = find.widgetWithText(TextButton, 'Stop reading');
      await tester.tap(find.byTooltip('Response actions').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read aloud'));
      await tester.pumpAndSettle();
      expect(speaker.spoken, <String>['First answer']);
      expect(stopReading, findsOneWidget);

      await tester.tap(find.byTooltip('Response actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read aloud'));
      await tester.pumpAndSettle();
      expect(speaker.stops, 1);
      expect(speaker.spoken, <String>['First answer', 'Second answer']);
      speaker.complete(0);
      await tester.pump();
      expect(stopReading, findsOneWidget);

      await tester.tap(stopReading);
      await tester.pump();
      expect(speaker.stops, 2);
      expect(stopReading, findsNothing);
    },
  );

  testWidgets('pushing a route stops active dictation and read aloud', (
    tester,
  ) async {
    final dictation = _FakeDictationEngine();
    final speaker = _FakeAnswerSpeaker();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(
              actions: <Widget>[
                IconButton(
                  tooltip: 'Open another page',
                  onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const Scaffold(body: Text('Next page')),
                    ),
                  ),
                  icon: const Icon(Icons.settings),
                ),
              ],
            ),
            body: Column(
              children: <Widget>[
                Expanded(
                  child: ChatTranscript(
                    answerSpeaker: speaker,
                    messages: const <TranscriptMessageView>[
                      TranscriptMessageView(
                        id: 'answer',
                        role: TranscriptRole.assistant,
                        content: 'Read this answer',
                      ),
                    ],
                  ),
                ),
                ChatComposer(
                  dictationEngine: dictation,
                  onSend: (_) async => true,
                  onStop: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byTooltip('Dictate message'));
    await tester.pump();
    await _openMenu(tester, 'Response actions');
    await tester.tap(find.text('Read aloud'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Open another page'));
    await tester.pumpAndSettle();
    expect(find.text('Next page'), findsOneWidget);
    expect(dictation.cancels, 1);
    expect(speaker.stops, 1);
  });
}

Future<void> _openMenu(WidgetTester tester, String label) async {
  await tester.tap(find.byTooltip(label));
  await tester.pumpAndSettle();
}

Future<void> _openEdit(WidgetTester tester) async {
  await _openMenu(tester, 'Message actions');
  await tester.tap(find.text('Edit and resend'));
  await tester.pumpAndSettle();
}

class _ComposerHarness extends StatefulWidget {
  const _ComposerHarness({super.key});

  @override
  State<_ComposerHarness> createState() => _ComposerHarnessState();
}

class _ComposerHarnessState extends State<_ComposerHarness> {
  int imagePicks = 0;
  int stops = 0;
  bool streaming = false;
  final List<String> sent = <String>[];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: ChatComposer(
          isStreaming: streaming,
          onPickImage: () => imagePicks += 1,
          onSend: (value) async {
            setState(() {
              sent.add(value);
              streaming = true;
            });
            return true;
          },
          onStop: () => setState(() {
            stops += 1;
            streaming = false;
          }),
        ),
      ),
    );
  }
}

class _TranscriptHarness extends StatefulWidget {
  const _TranscriptHarness({super.key, required this.scrollController});

  final ScrollController scrollController;

  @override
  State<_TranscriptHarness> createState() => _TranscriptHarnessState();
}

class _TranscriptHarnessState extends State<_TranscriptHarness> {
  late final List<TranscriptMessageView> _messages = List.generate(
    24,
    (index) => TranscriptMessageView(
      id: '$index',
      role: TranscriptRole.user,
      content: 'Message $index with enough text to occupy a row',
    ),
  );

  void append(String content) {
    setState(() {
      _messages.add(
        TranscriptMessageView(
          id: '${_messages.length}',
          role: TranscriptRole.assistant,
          content: content,
        ),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ChatTranscript(
      messages: _messages,
      scrollController: widget.scrollController,
    );
  }
}

class _FakeDictationEngine implements DictationEngine {
  DictationResultCallback? _onResult;
  VoidCallback? _onStopped;
  int cancels = 0;
  bool finishDuringStart = false;
  Future<bool>? pendingStart;

  @override
  Future<bool> start({
    required DictationResultCallback onResult,
    required VoidCallback onStopped,
    required SpeechErrorCallback onError,
  }) async {
    _onResult = onResult;
    _onStopped = onStopped;
    if (finishDuringStart) onStopped();
    if (pendingStart != null) return pendingStart!;
    return true;
  }

  void emit(String words, {required bool isFinal}) {
    _onResult?.call(words, isFinal);
  }

  @override
  Future<void> cancel() async {
    cancels += 1;
  }

  @override
  Future<void> stop() async {
    _onStopped?.call();
  }
}

class _FakeAnswerSpeaker implements AnswerSpeaker {
  final List<String> spoken = <String>[];
  final List<VoidCallback> _completions = <VoidCallback>[];
  int stops = 0;

  @override
  Future<void> speak(
    String text, {
    required SpeechStartedCallback onStarted,
    required VoidCallback onComplete,
    required SpeechErrorCallback onError,
  }) async {
    spoken.add(text);
    _completions.add(onComplete);
    onStarted();
  }

  void complete(int index) => _completions[index]();

  @override
  Future<void> stop() async {
    stops += 1;
  }
}
