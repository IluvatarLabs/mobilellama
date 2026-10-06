import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobollama/app.dart' show mobileLlamaTheme;
import 'package:mobollama/chat/composer.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/accounts_page.dart';
import 'package:mobollama/open_webui/screen.dart';

class _Preferences implements PreferencesDriver {
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
}

class _Secrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('iOS shared account sign-in, saved answer, and returning draft', (
    tester,
  ) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    Map<String, dynamic>? saved;
    var sends = 0;
    final folders = <String, Map<String, dynamic>>{};
    server.listen((request) async {
      Object result;
      final path = request.uri.path;
      if (path == '/api/config') {
        result = {
          'features': {'enable_folders': true},
        };
      } else if (path == '/api/v1/folders/shared') {
        result = [];
      } else if (path == '/api/v1/folders/') {
        if (request.method == 'POST') {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          folders['folder'] = {
            'id': 'folder',
            'user_id': 'device-test-account',
            'write_access': true,
            ...Map<String, dynamic>.from(body),
          };
          result = folders['folder']!;
        } else {
          result = folders.values.toList();
        }
      } else if (path == '/api/v1/folders/folder') {
        result = folders['folder']!;
      } else if (path == '/api/v1/chats/folder/folder/list') {
        result = [];
      } else if (path == '/api/v1/auths/')
        result = {
          'id': 'device-test-account',
          'name': 'Device test',
          'permissions': {},
        };
      else if (path == '/api/models')
        result = {
          'data': [
            {'id': 'test-model', 'name': 'Test model'},
          ],
        };
      else if (path == '/api/v1/chats/' || path == '/api/v1/chats/archived')
        result =
            saved == null ||
                path.endsWith('archived') ||
                request.uri.queryParameters['page'] != '1'
            ? []
            : [
                {'id': 'shared', 'title': 'Shared example'},
              ];
      else if (path == '/api/v1/chats/new') {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        saved = {
          'id': 'shared',
          'chat': {...body['chat'] as Map, 'title': 'Shared example'},
          'folder_id': body['folder_id'],
        };
        result = saved!;
      } else if (path == '/api/chat/completions') {
        sends++;
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final user = body['user_message'] as Map;
        final history = saved!['chat']['history'] as Map;
        final nodes = history['messages'] as Map;
        nodes[user['id']] = {...?nodes[user['id']] as Map?, ...user};
        nodes[body['id']] = {
          'id': body['id'],
          'role': 'assistant',
          'parentId': user['id'],
          'content': 'Your shared answer is saved on the server.',
          'done': true,
          'childrenIds': <String>[],
        };
        final children = nodes[user['id']]['childrenIds'] as List;
        if (!children.contains(body['id'])) children.add(body['id']);
        history['currentId'] = body['id'];
        saved!['current_message_id'] = body['id'];
        result = {'status': true, 'chat_id': 'shared', 'task_ids': []};
      } else if (path == '/api/v1/chats/shared')
        result = saved!;
      else if (path == '/api/tasks/chat/shared')
        result = {'task_ids': []};
      else {
        request.response.statusCode = 404;
        result = {'error': 'Unavailable'};
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
    final database = await openConversationDatabase(
      legacyServerProfileId: 'local',
      databasePath: ':memory:',
    );
    final accounts = WebUiAccounts(
      SettingsStore(_Preferences()),
      ProfileCredentials(_Secrets()),
      database.store.webUi,
    );
    final appearance = ValueNotifier<(Brightness, double)>((
      Brightness.light,
      1,
    ));
    await tester.pumpWidget(
      ValueListenableBuilder<(Brightness, double)>(
        valueListenable: appearance,
        builder: (context, value, _) => MaterialApp(
          theme: mobileLlamaTheme(value.$1),
          debugShowCheckedModeBanner: false,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(value.$2)),
            child: child!,
          ),
          home: WebUiAccountsPage(accounts: accounts),
        ),
      ),
    );
    await tester.tap(find.text('Connect Open WebUI'));
    await tester.pumpAndSettle();
    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    await tester.enterText(
      field('Server address'),
      'http://127.0.0.1:${server.port}',
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.text('Allow unencrypted access on this local network'),
    );
    await tester.tap(find.text('API key'));
    await tester.pump();
    await tester.enterText(field('API key'), 'device-test-token');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in and connect'));
    await tester.tap(find.text('Sign in and connect'));
    for (
      var i = 0;
      i < 100 && find.byType(WebUiScreen).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(WebUiScreen), findsOneWidget);
    await tester.pumpAndSettle();
    final composer = find.descendant(
      of: find.byType(ChatComposer),
      matching: find.byType(TextField),
    );
    await tester.enterText(composer, 'Can we continue this on my phone?');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    for (
      var i = 0;
      i < 100 &&
          find
              .text('Your shared answer is saved on the server.')
              .evaluate()
              .isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      find.text('Your shared answer is saved on the server.'),
      findsOneWidget,
    );
    expect(sends, 1);
    await tester.enterText(composer, 'Keep my next question as a draft');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New shared chat'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(composer).controller!.text, isEmpty);
    if (find.byTooltip('Shared chats').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Shared chats'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.widgetWithText(ListTile, 'Shared example'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Keep my next question as a draft',
    );
    expect(sends, 1);
    // A desktop-style sibling appears on refresh; browsing never sends.
    final history = saved!['chat']['history'] as Map;
    final nodes = history['messages'] as Map;
    final original = nodes[history['currentId']] as Map;
    nodes['alternate'] = {
      ...original,
      'id': 'alternate',
      'content': 'A retained alternative answer.',
    };
    (nodes[original['parentId']]['childrenIds'] as List).add('alternate');
    await tester.tap(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byTooltip('Chat actions'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Refresh conversation'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Next version'));
    await tester.tap(find.byTooltip('Next version'));
    await tester.pumpAndSettle();
    expect(find.text('Viewing an earlier version'), findsOneWidget);
    expect(find.text('A retained alternative answer.'), findsOneWidget);
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Keep my next question as a draft',
    );
    expect(sends, 1);
    await binding.takeScreenshot('shared-versions-preview');
    await tester.tap(find.text('Continue from this version'));
    await tester.pumpAndSettle();
    for (
      var i = 0;
      tester.widget<WebUiScreen>(find.byType(WebUiScreen)).workspace.busy &&
          i < 100;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(
      find.text('Next message follows the selected version'),
      findsOneWidget,
    );

    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('shared-chat-light');
    appearance.value = (Brightness.dark, 1);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('shared-chat-dark');
    appearance.value = (Brightness.dark, 1.8);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('shared-chat-large-text');
    appearance.value = (Brightness.light, 1);
    await tester.pumpAndSettle();
    if (find.byTooltip('Shared chats').evaluate().isNotEmpty) {
      await tester.tap(find.byTooltip('Shared chats'));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.text('Folders'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('New folder'));
    await tester.pumpAndSettle();
    await tester.enterText(field('Name'), 'Research');
    await tester.enterText(
      field('Folder instructions'),
      'Explain clearly and include sources.',
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Research'));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Explain clearly and include sources.'),
      findsOneWidget,
    );
    await binding.takeScreenshot('shared-folder-light');
    await tester.tap(find.text('New chat in this folder'));
    await tester.pumpAndSettle();
    expect(find.text('Folder: Research'), findsOneWidget);
    await tester.enterText(composer, 'A question in Research');
    await tester.pump();
    await tester.tap(find.byTooltip('Send'));
    for (var i = 0; sends < 2 && i < 100; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(sends, 2);
    expect(saved!['folder_id'], 'folder');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await database.close();
    await server.close(force: true);
  });
}
