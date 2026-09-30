import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:mobollama/app.dart';
import 'package:mobollama/chat/background_execution.dart';
import 'package:mobollama/chat/chat_controller.dart';
import 'package:mobollama/chat/history.dart';
import 'package:mobollama/data/attachment_reference_codec.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/ollama/ollama_client.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const _fixtureOrigin = String.fromEnvironment(
  'QOL_FIXTURE_ORIGIN',
  defaultValue: 'http://127.0.0.1:18080',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('chat QoL workflow survives navigation and an app switch', (
    tester,
  ) async {
    expect(
      Platform.isIOS,
      isTrue,
      reason: 'This integration workflow proves the iOS native bridge.',
    );
    const backgroundChannel = MethodChannel(
      'app.mobollama/chat_background_execution',
    );
    await backgroundChannel.invokeMethod<void>('begin', <String, Object>{
      'runId': 'qol-native-registration-probe',
    });
    await backgroundChannel.invokeMethod<void>('end', <String, Object>{
      'runId': 'qol-native-registration-probe',
    });

    final harness = await _QolHarness.open();
    final appDisposed = Completer<void>();
    await tester.pumpWidget(
      MobOllamaApp(
        controller: harness.controller,
        onDispose: () async {
          await harness.closeExternalResources();
          if (!appDisposed.isCompleted) appDisposed.complete();
        },
      ),
    );

    try {
      await _pumpUntil(
        tester,
        () =>
            harness.controller.initialized &&
            harness.controller.connectionState ==
                ServerConnectionState.connected &&
            find.byTooltip('Send').evaluate().isNotEmpty,
        description: 'connected chat composer',
      );

      await _enterComposer(tester, harness.controller, 'SLOW_HOME primary run');
      await tester.tap(find.byTooltip('Send'));
      await _pumpUntil(
        tester,
        () => harness.controller.messages.any(
          (message) => message.content.contains('HOME_SLOW_STARTED'),
        ),
        description: 'first streamed response chunk',
      );
      expect(find.textContaining('HOME_SLOW_STARTED'), findsWidgets);
      final homeConversationId = harness.controller.conversation!.id;
      // Parent automation waits for this marker, presses Simulator Home, then
      // returns to the app while the Mac fixture keeps this response open.
      debugPrint('QOL_SLOW_RESPONSE_READY');
      await Future<void>.delayed(const Duration(seconds: 6));
      await tester.pump();
      await _pumpUntil(
        tester,
        () =>
            harness.controller.canQueueOrSend &&
            !harness.controller.isSubmitting &&
            harness.controller.isStreaming &&
            _composer().evaluate().isNotEmpty,
        description: 'queue-ready composer after native return',
        diagnostics: () => _queueDiagnostics(tester, harness.controller),
      );
      expect(harness.controller.canQueueOrSend, isTrue);
      expect(harness.controller.isSubmitting, isFalse);
      expect(harness.controller.isStreaming, isTrue);
      expect(tester.widget<TextField>(_composer()).controller?.text, isEmpty);
      debugPrint(
        'QOL_POST_RETURN_STATE ${_queueDiagnostics(tester, harness.controller)}',
      );

      await _queue(tester, harness.controller, 'QUEUE_ALPHA');
      await _queue(tester, harness.controller, 'QUEUE_EDIT_ME');
      await _queue(tester, harness.controller, 'QUEUE_REMOVE_ME');
      // With the keyboard up the short viewport shows the queue summary.
      if (tester.view.viewInsets.bottom > 0) {
        expect(find.textContaining('3 queued'), findsOneWidget);
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await _pumpUntil(
        tester,
        () => find.text('Queued (3)').evaluate().isNotEmpty,
        description: 'full queue panel after keyboard dismissal',
      );
      expect(find.text('Queued (3)'), findsOneWidget);

      await tester.tap(find.byTooltip('Edit queued message').at(1));
      final queueEditor = find.byWidgetPredicate(
        (widget) =>
            widget is TextField && widget.decoration?.labelText == 'Message',
      );
      await _pumpUntil(
        tester,
        () => queueEditor.evaluate().isNotEmpty,
        description: 'queued message editor',
      );
      await tester.enterText(queueEditor, 'QUEUE_BETA');
      await tester.tap(find.text('Save'));
      await _pumpUntil(
        tester,
        () => harness.controller.queuedPrompts.any(
          (prompt) => prompt.text == 'QUEUE_BETA',
        ),
        description: 'saved queued message edit',
      );

      await tester.tap(find.byTooltip('Remove queued message').at(2));
      await _pumpUntil(
        tester,
        () => harness.controller.queuedPrompts.length == 2,
        description: 'queued message removal',
      );
      expect(find.text('Queued (2)'), findsOneWidget);
      expect(find.text('QUEUE_REMOVE_ME'), findsNothing);

      final dragListeners = find.byType(ReorderableDragStartListener);
      await _pumpUntil(
        tester,
        () =>
            dragListeners.evaluate().length == 2 &&
            tester
                .widget<ReorderableDragStartListener>(dragListeners.at(1))
                .enabled,
        description: 'queue row enabled after removal',
      );
      debugPrint('QOL_QUEUE_BEFORE_REORDER');
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.pump();

      final dragHandles = find.byIcon(Icons.drag_handle_rounded);
      final start = tester.getCenter(dragHandles.at(1));
      final first = tester.getCenter(dragHandles.at(0));
      await tester.timedDrag(
        dragHandles.at(1),
        Offset(first.dx - start.dx, first.dy - start.dy - 30),
        const Duration(seconds: 1),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await _pumpUntil(
        tester,
        () => harness.controller.queuedPrompts.first.text == 'QUEUE_BETA',
        description: 'queued message reorder',
      );
      expect(harness.controller.queuedPrompts.last.text, 'QUEUE_ALPHA');
      debugPrint('QOL_QUEUE_READY');
      await Future<void>.delayed(const Duration(seconds: 3));

      await _openChat(tester, 'lab-chat');
      await _enterComposer(tester, harness.controller, 'LAB_DRAFT_MARKER');
      expect(harness.controller.draftText, 'LAB_DRAFT_MARKER');
      await _openChat(tester, homeConversationId);
      await harness.release('slow');

      await _pumpUntil(
        tester,
        () => harness.controller.messages.any(
          (message) => message.content.contains('HOME_BETA_STARTED'),
        ),
        timeout: const Duration(seconds: 20),
        description: 'edited and reordered queued response',
      );
      expect(find.textContaining('HOME_BETA_STARTED'), findsWidgets);
      await tester.tap(find.byTooltip('Stop response'));
      await _pumpUntil(
        tester,
        () => !harness.controller.isStreaming,
        description: 'stopped queued response',
      );
      await harness.release('beta');
      expect(
        harness.controller.messages.last.status,
        MessageStatus.interrupted,
      );
      expect(harness.controller.queuedPrompts.single.text, 'QUEUE_ALPHA');
      expect(find.text('Resume'), findsOneWidget);

      await tester.tap(find.text('Resume'));
      await _pumpUntil(
        tester,
        () =>
            !harness.controller.isStreaming &&
            harness.controller.queuedPrompts.isEmpty &&
            harness.controller.messages.any(
              (message) => message.content.contains('HOME_ALPHA_COMPLETE'),
            ),
        description: 'resumed queue completion',
      );
      expect(find.textContaining('HOME_ALPHA_COMPLETE'), findsWidgets);

      await _openChat(tester, 'lab-chat');
      expect(_composer(), findsOneWidget);
      expect(
        tester.widget<TextField>(_composer()).controller?.text,
        'LAB_DRAFT_MARKER',
      );
      await _openChat(tester, homeConversationId);

      await _attachImage(tester, expectedCount: 1);
      await _attachImage(tester, expectedCount: 2);
      expect(find.byTooltip('Remove image 1'), findsOneWidget);
      expect(find.byTooltip('Remove image 2'), findsOneWidget);
      await tester.tap(find.byTooltip('Remove image 1'));
      await tester.pumpAndSettle();
      expect(harness.controller.pendingImageReferences, hasLength(1));
      await _attachImage(tester, expectedCount: 2);

      await _enterComposer(tester, harness.controller, 'IMAGE_PAIR');
      await tester.tap(find.byTooltip('Send'));
      await _pumpUntil(
        tester,
        () =>
            !harness.controller.isStreaming &&
            harness.controller.messages.any(
              (message) => message.content.contains('HOME_IMAGE_COMPLETE'),
            ),
        description: 'two-image response',
      );
      final imageMessage = harness.controller.messages
          .where((message) => message.role == MessageRole.user)
          .last;
      expect(imageMessage.imageReferences, hasLength(2));
      expect(find.bySemanticsLabel('Open attached image'), findsNWidgets(2));
      final imageThumbnail = find.bySemanticsLabel('Open attached image').first;
      await tester.ensureVisible(imageThumbnail);
      await tester.pumpAndSettle();
      await tester.tap(imageThumbnail);
      await tester.pumpAndSettle();
      final imageViewer = find.byType(InteractiveViewer);
      await _pumpUntil(tester, () {
        final decodedImages = find.descendant(
          of: imageViewer,
          matching: find.byType(RawImage),
        );
        return imageViewer.evaluate().length == 1 &&
            decodedImages.evaluate().isNotEmpty &&
            tester
                .widgetList<RawImage>(decodedImages)
                .any((image) => image.image != null) &&
            find.byIcon(Icons.broken_image_outlined).evaluate().isEmpty;
      }, description: 'decoded image viewer');
      expect(find.byIcon(Icons.broken_image_outlined), findsNothing);
      debugPrint('QOL_IMAGE_VIEWER_READY');
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.tap(find.byTooltip('Close image'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Chat actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Find in chat'));
      await tester.pumpAndSettle();
      final findField = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText == 'Find in chat',
      );
      await tester.enterText(findField, 'FIND_TARGET');
      await tester.pumpAndSettle();
      expect(find.text('1/1'), findsOneWidget);
      debugPrint('QOL_FIND_READY');
      await Future<void>.delayed(const Duration(seconds: 3));
      await tester.pump();
      await tester.tap(find.byTooltip('Next match'));
      await tester.tap(find.byTooltip('Previous match'));
      await tester.tap(find.byTooltip('Close find'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Copy code'), findsOneWidget);
      expect(find.byType(Math), findsOneWidget);
      debugPrint('QOL_FIND_MATH_READY');
      await Future<void>.delayed(const Duration(seconds: 3));

      final requests = await harness.fixtureRequests();
      final chatRequests = requests
          .where((request) => request['model'] == 'qol-model')
          .toList(growable: false);
      expect(chatRequests.take(3).map((request) => request['prompt']), [
        'SLOW_HOME primary run',
        'QUEUE_BETA',
        'QUEUE_ALPHA',
      ]);
      expect(chatRequests.take(3).map((request) => request['route']).toSet(), {
        'home',
      });
      expect(
        chatRequests.any((request) => request['prompt'] == 'QUEUE_REMOVE_ME'),
        isFalse,
      );
      final imageRequest = chatRequests.singleWhere(
        (request) => request['prompt'] == 'IMAGE_PAIR',
      );
      expect(imageRequest['route'], 'home');
      expect(imageRequest['imageCount'], 2);
      debugPrint('QOL_WORKFLOW_COMPLETE');
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await appDisposed.future.timeout(const Duration(seconds: 15));
    }
  });
}

Finder _composer() => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.hintText == 'Message',
);

Future<void> _enterComposer(
  WidgetTester tester,
  ChatController controller,
  String text,
) async {
  final composer = _composer();
  await _pumpUntil(
    tester,
    () =>
        composer.evaluate().isNotEmpty &&
        tester.widget<TextField>(composer).enabled != false &&
        controller.canQueueOrSend,
    description: 'enabled composer for $text',
    diagnostics: () => _queueDiagnostics(tester, controller),
  );
  await tester.ensureVisible(composer);
  await tester.tap(composer);
  await tester.pump();
  await tester.enterText(composer, text);
  await _pumpUntil(
    tester,
    () =>
        tester.widget<TextField>(_composer()).controller?.text == text &&
        controller.draftText == text,
    description: 'composer text $text',
    diagnostics: () => _queueDiagnostics(tester, controller),
  );
}

Future<void> _queue(
  WidgetTester tester,
  ChatController controller,
  String text,
) async {
  final previousCount = controller.queuedPrompts.length;
  await _enterComposer(tester, controller, text);
  await _pumpUntil(
    tester,
    () =>
        tester.widget<TextField>(_composer()).controller?.text == text &&
        find.byTooltip('Queue message').evaluate().isNotEmpty,
    description: 'Queue message control for $text',
    diagnostics: () => _queueDiagnostics(tester, controller),
  );
  await tester.tap(find.byTooltip('Queue message'));
  await _pumpUntil(
    tester,
    () => controller.queuedPrompts.length == previousCount + 1,
    description: 'durable queued prompt $text',
    diagnostics: () => _queueDiagnostics(tester, controller),
  );
}

Future<void> _openChat(WidgetTester tester, String expectedId) async {
  await tester.tap(find.byTooltip('Open chats'));
  final row = find.byWidgetPredicate(
    (widget) => widget is ChatHistoryRow && widget.chat.id == expectedId,
  );
  await _pumpUntil(
    tester,
    () => row.evaluate().isNotEmpty,
    description: 'history row $expectedId',
  );
  await tester.ensureVisible(row);
  await tester.tap(row);
  await _pumpUntil(
    tester,
    () =>
        find.byType(Drawer).evaluate().isEmpty &&
        _currentConversationId(tester) == expectedId,
    description: 'open chat $expectedId',
  );
}

String? _currentConversationId(WidgetTester tester) {
  final app = tester.widget<MobOllamaApp>(find.byType(MobOllamaApp));
  return app.controller.conversation?.id;
}

Future<void> _attachImage(
  WidgetTester tester, {
  required int expectedCount,
}) async {
  await tester.tap(find.byTooltip('Add attachment'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Photo library'));
  await _pumpUntil(
    tester,
    () => find.byTooltip('Remove image $expectedCount').evaluate().isNotEmpty,
    description: 'attach image $expectedCount',
  );
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 12),
  required String description,
  String Function()? diagnostics,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  if (!condition()) {
    final state = diagnostics?.call();
    throw TestFailure(
      'Timed out waiting for $description.'
      '${state == null ? '' : ' State: $state'}',
    );
  }
  await tester.pump();
}

String _queueDiagnostics(WidgetTester tester, ChatController controller) {
  final fields = _composer().evaluate();
  final text = fields.isEmpty
      ? '<missing>'
      : tester.widget<TextField>(_composer()).controller?.text ??
            '<no controller>';
  return 'canQueueOrSend=${controller.canQueueOrSend} '
      'isSubmitting=${controller.isSubmitting} '
      'isStreaming=${controller.isStreaming} '
      'conversationConnected=${controller.conversationConnected} '
      'selectedModel=${controller.selectedModel} '
      'composerText=${jsonEncode(text)} '
      'queueControls=${find.byTooltip('Queue message').evaluate().length}';
}

final class _QolHarness {
  _QolHarness._({
    required this.controller,
    required this.database,
    required this.client,
    required this.root,
  });

  final ChatController controller;
  final OpenConversationDatabase database;
  final http.Client client;
  final Directory root;
  bool _externalResourcesClosed = false;

  static Future<_QolHarness> open() async {
    final fixture = Uri.parse(_fixtureOrigin);
    if ((fixture.scheme != 'http' && fixture.scheme != 'https') ||
        fixture.host.isEmpty ||
        fixture.pathSegments.isNotEmpty ||
        fixture.hasQuery ||
        fixture.hasFragment) {
      throw StateError('QOL_FIXTURE_ORIGIN must be an HTTP(S) origin.');
    }
    final reset = await http
        .post(fixture.resolve('/test/reset'), body: '{}')
        .timeout(const Duration(seconds: 5));
    if (reset.statusCode != 200) {
      throw StateError('QoL fixture reset failed with ${reset.statusCode}.');
    }

    final temporary = await getTemporaryDirectory();
    final root = await Directory(
      path.join(
        temporary.path,
        'mobollama-qol-${DateTime.now().microsecondsSinceEpoch}',
      ),
    ).create(recursive: true);
    final imageRoot = await Directory(path.join(root.path, 'chat-images'))
        .create(recursive: true);
    final images = await _FixtureImageStore.create(imageRoot);
    final settings = SettingsStore(_MemoryPreferences());
    final origin = SettingsStore.endpointOrigin(_fixtureOrigin);
    await settings.upsertProfile(
      ServerProfile(
        id: 'home',
        name: 'Home fixture',
        protocol: ServerProtocol.ollama,
        baseUrl: fixture.replace(path: '/home').toString(),
        acknowledgedInsecureOrigin: origin,
      ),
    );
    await settings.upsertProfile(
      ServerProfile(
        id: 'lab',
        name: 'Lab fixture',
        protocol: ServerProtocol.ollama,
        baseUrl: fixture.replace(path: '/lab').toString(),
        acknowledgedInsecureOrigin: origin,
      ),
    );
    await settings.setActiveProfile('home');

    final database = await openConversationDatabase(
      databasePath: path.join(root.path, 'qol.sqlite'),
      legacyServerProfileId: 'home',
      referenceCodec: RootedAttachmentReferenceCodec(imageRoot.path),
    );
    await database.store.createConversation(
      id: 'lab-chat',
      serverProfileId: 'lab',
      selectedModel: 'qol-model',
      systemPrompt: '',
    );
    await database.store.appendMessage(
      id: 'lab-user',
      conversationId: 'lab-chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Lab saved chat',
    );
    await database.store.appendMessage(
      id: 'lab-assistant',
      conversationId: 'lab-chat',
      role: MessageRole.assistant,
      status: MessageStatus.complete,
      content: 'LAB_SAVED_ANSWER',
    );

    final client = http.Client();
    var nextId = 0;
    final controller = ChatController(
      conversations: database.store,
      settings: settings,
      secrets: _MemorySecrets(),
      images: images,
      backgroundExecution: Platform.isIOS
          ? NativeChatBackgroundExecution()
          : const NoopChatBackgroundExecution(),
      ollamaClientFactory: (baseUrl) => OllamaClient(
        baseUrl: baseUrl,
        client: client,
        streamingClientFactory: http.Client.new,
      ),
      webAgentFactory: ({required ollama, required apiKey}) =>
          throw StateError('Web Agent is disabled in the QoL fixture.'),
      idFactory: () => 'qol-${++nextId}',
    );
    return _QolHarness._(
      controller: controller,
      database: database,
      client: client,
      root: root,
    );
  }

  Future<List<Map<String, Object?>>> fixtureRequests() async {
    final response = await client
        .get(Uri.parse(_fixtureOrigin).resolve('/test/requests'))
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError('QoL fixture log failed with ${response.statusCode}.');
    }
    final decoded = jsonDecode(response.body) as Map<String, Object?>;
    return (decoded['requests']! as List)
        .map((value) => Map<String, Object?>.from(value as Map))
        .toList(growable: false);
  }

  Future<void> release(String name) async {
    final response = await client
        .post(
          Uri.parse(_fixtureOrigin).resolve('/test/release/$name'),
          body: '{}',
        )
        .timeout(const Duration(seconds: 5));
    if (response.statusCode != 200) {
      throw StateError(
        'QoL fixture release $name failed with ${response.statusCode}.',
      );
    }
  }

  Future<void> closeExternalResources() async {
    if (_externalResourcesClosed) return;
    _externalResourcesClosed = true;
    client.close();
    await database.close();
    if (await root.exists()) await root.delete(recursive: true);
  }
}

final class _MemoryPreferences implements PreferencesDriver {
  final Map<String, Object> _values = {};

  @override
  bool? getBool(String key) => _values[key] as bool?;

  @override
  String? getString(String key) => _values[key] as String?;

  @override
  Future<void> setBool(String key, bool value) async => _values[key] = value;

  @override
  Future<void> setString(String key, String value) async =>
      _values[key] = value;
}

final class _MemorySecrets implements SecretStore {
  final Map<String, String> _values = {};

  @override
  Future<void> delete(String key) async => _values.remove(key);

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}

final class _FixtureImageStore implements ImageAttachmentStore {
  _FixtureImageStore._(this.root, this.sources);

  final Directory root;
  final List<File> sources;
  int _nextSource = 0;
  int _nextFile = 0;

  static Future<_FixtureImageStore> create(Directory root) async {
    final sourceRoot = await Directory(
      path.join(root.parent.path, 'image-fixtures'),
    ).create(recursive: true);
    final data = await rootBundle.load('assets/mobilellama-icon.png');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final sources = <File>[];
    for (var index = 0; index < 3; index++) {
      final source = File(path.join(sourceRoot.path, 'fixture-$index.png'));
      await source.writeAsBytes(bytes, flush: true);
      sources.add(source);
    }
    return _FixtureImageStore._(root, sources);
  }

  @override
  Future<String?> pickAndCopy({
    required String conversationId,
    bool camera = false,
  }) async {
    final source = sources[_nextSource++ % sources.length];
    final directory = await Directory(path.join(root.path, conversationId))
        .create(recursive: true);
    final target = File(path.join(directory.path, 'picked-${++_nextFile}.png'));
    await source.copy(target.path);
    return target.path;
  }

  @override
  Future<String> readAsBase64(String reference) async =>
      base64Encode(await File(reference).readAsBytes());

  @override
  Future<int> sizeInBytes(String reference) => File(reference).length();

  @override
  Future<void> deleteReference(String reference) async {
    final file = File(reference);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    final directory = Directory(path.join(root.path, conversationId));
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  @override
  Future<String> writeBytes({
    required String conversationId,
    required List<int> bytes,
    required String sourceName,
  }) async {
    final directory = await Directory(path.join(root.path, conversationId))
        .create(recursive: true);
    final target = File(
      path.join(directory.path, 'restored-${++_nextFile}.png'),
    );
    await target.writeAsBytes(bytes, flush: true);
    return target.path;
  }
}
