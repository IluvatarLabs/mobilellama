import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:mobollama/app.dart' show mobileLlamaTheme;
import 'package:mobollama/chat/composer.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/ollama/connection_options.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/screen.dart';
import 'package:mobollama/open_webui/workspace.dart';

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
    'iOS temporary shared chat uses a real socket, waits for outlet, and saves once',
    (tester) async {
      const url = 'http://127.0.0.1:8768/team';
      final client = OpenWebUiClient(
        baseUrl: url,
        options: ConnectionOptions(apiKey: 'fixture-token'),
      );
      final session = WebUiSession(
        'profile',
        WebUiIdentity(
          server: client.serverId,
          userId: 'fixture-user',
          name: 'Fixture account',
          permissions: {},
        ),
        client,
      );
      final database = await openConversationDatabase(
        legacyServerProfileId: 'direct',
        databasePath: ':memory:',
      );
      final memory = _Memory();
      final accounts = WebUiAccounts(
        SettingsStore(memory),
        ProfileCredentials(memory),
        database.store.webUi,
      );
      await accounts.store.unlock(session.capture());
      await accounts.store.saveDraft(session.capture(), 'new:profile', {
        'text': 'Preserve my ordinary shared draft',
      });
      final w = WebUiWorkspace(accounts, session);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: mobileLlamaTheme(Brightness.light),
          home: WebUiScreen(workspace: w),
        ),
      );
      for (var i = 0; (!w.online || w.model.isEmpty) && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(w.online, isTrue);
      await tester.tap(find.byTooltip('Chat mode'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Temporary chat'));
      await tester.pumpAndSettle();
      final composer = find.descendant(
        of: find.byType(ChatComposer).last,
        matching: find.byType(TextField),
      );
      for (
        var i = 0;
        !tester
                .widget<ChatComposer>(find.byType(ChatComposer).last)
                .canSubmit &&
            i < 100;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.enterText(composer, 'Ask through a live connection');
      await tester.pump();
      await tester.tap(find.byTooltip('Send').last);
      for (
        var i = 0;
        find
                .text('Final temporary answer after server processing.')
                .evaluate()
                .isEmpty &&
            i < 100;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.text('Final temporary answer after server processing.'),
        findsOneWidget,
      );
      await tester.enterText(composer, 'Keep this unsent follow-up');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      final stats = jsonDecode(
        (await http.get(Uri.parse('$url/fixture/stats'))).body,
      ) as Map;
      expect(stats['chats'], 0);
      expect(stats['sends'], 1);
      expect(stats['heartbeats'][stats['last_sid']], greaterThan(0));
      expect(await accounts.store.chats(session.capture()), isEmpty);
      expect(
        (await accounts.store.draft(session.capture(), 'new:profile'))!['text'],
        'Preserve my ordinary shared draft',
      );
      await binding.takeScreenshot('shared-temporary-live-socket');
      await tester.tap(find.widgetWithText(TextButton, 'Save'));
      for (var i = 0; w.conversation == null && i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(w.conversation, isNotNull);
      expect(
        w.messages.last.content,
        'Final temporary answer after server processing.',
      );
      expect(w.draft, 'Keep this unsent follow-up');
      expect(
        jsonDecode(
          (await http.get(Uri.parse('$url/fixture/stats'))).body,
        )['chats'],
        1,
      );
      await tester.tap(find.byTooltip('New shared chat'));
      await tester.pumpAndSettle();
      expect(w.draft, 'Preserve my ordinary shared draft');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await database.close();
    },
  );
}
