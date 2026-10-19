import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobollama/app.dart' show mobileLlamaTheme;
import 'package:mobollama/chat/chat_controller.dart';
import 'package:mobollama/chat/chat_screen.dart';
import 'package:mobollama/chat/composer.dart';
import 'package:mobollama/data/local_image_store.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/document_attachment.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/data/temporary_chat.dart';
import 'package:mobollama/ollama/ollama_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class _Memory implements PreferencesDriver, SecretStore {
  final values = <String, Object>{};
  @override
  bool? getBool(String key) => values[key] as bool?;
  @override
  String? getString(String key) => values[key] as String?;
  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<String?> read(String key) async => getString(key);
  @override
  Future<void> write(String key, String value) => setString(key, value);
  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'iOS temporary chat saves explicitly and cleans its session on exit',
    (tester) async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        final response = switch (request.uri.path) {
          '/api/version' => {'version': '0.12.6'},
          '/api/tags' => {
            'models': [
              {
                'name': 'test-model',
                'model': 'test-model',
                'modified_at': '',
                'size': 1,
                'digest': 'fixture',
                'details': {},
              },
            ],
          },
          '/api/show' => {'details': {}, 'capabilities': []},
          '/api/chat' => {
            'model': 'test-model',
            'message': {
              'role': 'assistant',
              'content': 'This answer stays temporary until you save it.',
            },
            'done': true,
          },
          _ => {},
        };
        request.response.write('${jsonEncode(response)}\n');
        await request.response.close();
      });
      final memory = _Memory();
      final settings = SettingsStore(memory);
      final url = 'http://127.0.0.1:${server.port}';
      await settings.upsertProfile(
        ServerProfile(
          id: 'test',
          name: 'Test server',
          protocol: ServerProtocol.ollama,
          baseUrl: url,
          acknowledgedInsecureOrigin: url,
        ),
      );
      await settings.setActiveProfile('test');
      await settings.acknowledgeDestination(ServerProtocol.ollama, url);
      final root = await getTemporaryDirectory();
      await TemporaryChatSession.clearAbandoned();
      final images = await LocalImageAttachmentStore.at(
        Directory('${root.path}/temporary-workflow-images/chat-images'),
      );
      final databasePath = '${root.path}/temporary-workflow-upgrade.sqlite';
      await deleteDatabase(databasePath);
      final legacy = await openConversationDatabase(
        legacyServerProfileId: 'test',
        databasePath: databasePath,
        schemaVersion: 12,
        referenceCodec: images.referenceCodec,
      );
      final image = await images.writeBytes(
        conversationId: 'upgrade',
        bytes: base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6XkAAAAASUVORK5CYII=',
        ),
        sourceName: 'photo.png',
      );
      final document = await images.writeBytes(
        conversationId: 'upgrade',
        bytes: utf8.encode('Retained document bytes'),
        sourceName: 'note.txt',
      );
      await legacy.store.createConversation(
        id: 'upgrade',
        serverProfileId: 'test',
        selectedModel: 'test-model',
        systemPrompt: 'Saved instructions',
      );
      await legacy.store.appendMessage(
        id: 'legacy-user',
        conversationId: 'upgrade',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Upgrade my history',
        imageReferences: [image],
        documents: [
          DocumentAttachment(
            id: 'doc',
            name: 'note.txt',
            mimeType: 'text/plain',
            reference: document,
            text: 'Retained document bytes',
          ),
        ],
      );
      await legacy.store.appendMessage(
        id: 'legacy-answer',
        conversationId: 'upgrade',
        role: MessageRole.assistant,
        status: MessageStatus.complete,
        content: 'History retained',
      );
      await legacy.close();
      final database = await openConversationDatabase(
        legacyServerProfileId: 'test',
        databasePath: databasePath,
        schemaVersion: 13,
        referenceCodec: images.referenceCodec,
      );
      final upgraded = (await database.store.openConversation(
        serverProfileId: 'test',
        id: 'upgrade',
        allBranches: true,
      ))!;
      expect(upgraded.conversation.activeTipId, 'legacy-answer');
      expect(upgraded.allNodes.length, 2);
      expect(await File(image).exists(), isTrue);
      expect(await File(document).readAsString(), 'Retained document bytes');
      var id = 0;
      final controller = ChatController(
        conversations: database.store,
        settings: settings,
        secrets: memory,
        images: images,
        ollamaClientFactory: (url) => OllamaClient(
          baseUrl: url,
          client: http.Client(),
          streamingClientFactory: http.Client.new,
        ),
        webAgentFactory: ({required ollama, required apiKey}) =>
            throw UnsupportedError('Not used'),
        idFactory: () => 'native-temp-${++id}',
      );
      await controller.initialize();
      expect(await controller.deleteConversation('upgrade'), isTrue);
      expect(await File(image).exists(), isFalse);
      expect(await File(document).exists(), isFalse);
      controller.setDraftText('Keep my ordinary draft');
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: mobileLlamaTheme(Brightness.light),
          home: ChatScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Open chats'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Temporary chat'));
      await tester.pumpAndSettle();
      expect(
        find.text('Temporary chat · Not saved in history'),
        findsOneWidget,
      );
      final composer = find.descendant(
        of: find.byType(ChatComposer).last,
        matching: find.byType(TextField),
      );
      await tester.enterText(composer, 'A temporary question');
      await tester.pump();
      await tester.tap(find.byTooltip('Send'));
      for (
        var i = 0;
        i < 100 &&
            find
                .text('This answer stays temporary until you save it.')
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.text('This answer stays temporary until you save it.'),
        findsOneWidget,
      );
      await tester.enterText(composer, 'Preserve this follow-up');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      expect(controller.history, isEmpty);
      await binding.takeScreenshot('temporary-chat-light');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      await tester.pumpAndSettle();
      expect(controller.history.length, 1);
      expect(controller.draftText, 'Preserve this follow-up');
      await controller.newConversation();
      expect(controller.draftText, 'Keep my ordinary draft');
      await tester.pumpAndSettle();
      final sessions = Directory('${root.path}/MobileLlamaTemporary');
      for (
        var i = 0;
        i < 100 && await sessions.exists() && !(await sessions.list().isEmpty);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(await sessions.list().isEmpty, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.shutdown();
      controller.dispose();
      await database.close();
      final reopened = await openConversationDatabase(
        legacyServerProfileId: 'test',
        databasePath: databasePath,
        schemaVersion: 13,
        referenceCodec: images.referenceCodec,
      );
      expect(
        await reopened.store.openConversation(
          serverProfileId: 'test',
          id: 'upgrade',
        ),
        isNull,
      );
      expect((await reopened.store.listAllConversations()).length, 1);
      await reopened.close();
      await deleteDatabase(databasePath);
      await Directory('${root.path}/temporary-workflow-images')
          .delete(recursive: true);
      await server.close(force: true);
    },
  );
}
