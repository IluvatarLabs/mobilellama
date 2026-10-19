import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/run.dart';
import 'package:mobollama/open_webui/workspace.dart';
import 'package:mobollama/ollama/connection_options.dart';

import '../support/chat_fixture.dart';

Future<void> until(bool Function() ready) async {
  for (var attempt = 0; !ready() && attempt < 300; attempt++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  test('a queued follow-up uses the saved answer and an offline draft returns to its own chat', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    Map<String, dynamic>? saved;
    final requests = <Map<String, dynamic>>[];
    var taskActive = false, offline = false;
    final client = OpenWebUiClient(
      baseUrl: 'http://127.0.0.1:1',
      options: ConnectionOptions(apiKey: 'token'),
      client: MockClient((request) async {
        if (offline) throw const SocketException('Offline');
        Object result;
        final path = request.url.path;
        if (path == '/api/models') {
          result = {
            'data': [
              {'id': 'model', 'name': 'Model'},
            ],
          };
        } else if (path == '/api/v1/chats/' || path == '/api/v1/chats/archived')
          result =
              path.endsWith('archived') ||
                  request.url.queryParameters['page'] != '1' ||
                  saved == null
              ? []
              : [
                  {'id': 'chat', 'title': 'Saved chat'},
                ];
        else if (path == '/api/v1/chats/new') {
          saved = {'id': 'chat', 'chat': jsonDecode(request.body)['chat']};
          result = saved!;
        } else if (path == '/api/v1/chats/chat')
          result = saved!;
        else if (path == '/api/tasks/chat/chat')
          result = {
            'task_ids': taskActive ? ['task'] : [],
          };
        else if (path == '/api/chat/completions') {
          final body = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          requests.add(body);
          final history = saved!['chat']['history'] as Map;
          final nodes = history['messages'] as Map;
          final user = body['user_message'] as Map;
          nodes[user['id']] = user;
          nodes[body['id']] = {
            'id': body['id'],
            'parentId': user['id'],
            'role': 'assistant',
            'content': 'Answer ${requests.length}',
            'done': false,
          };
          history['currentId'] = body['id'];
          saved!['current_message_id'] = body['id'];
          taskActive = true;
          result = {
            'status': true,
            'chat_id': 'chat',
            'task_ids': ['task'],
          };
        } else {
          throw StateError('Unexpected ${request.method} $path');
        }
        return http.Response(
          jsonEncode(result),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    final session = WebUiSession(
      'web-profile',
      WebUiIdentity(
        server: client.serverId,
        userId: 'user',
        name: 'User',
        permissions: {},
      ),
      client,
    );
    await f.store.webUi.unlock(session.capture());
    final accounts = WebUiAccounts(
      f.settings,
      ProfileCredentials(f.secrets),
      f.store.webUi,
    );
    final workspace = WebUiWorkspace(accounts, session);
    addTearDown(workspace.dispose);
    await workspace.initialize();
    expect(await workspace.send('First turn'), isTrue);
    await until(
      () =>
          workspace.run?.state == WebUiRunState.running && requests.length == 1,
    );
    expect(await workspace.send('Follow-up'), isTrue);
    expect(workspace.queue, hasLength(1));
    final firstAssistant = requests.first['id'];
    saved!['chat']['history']['messages'][firstAssistant]['done'] = true;
    taskActive = false;
    await workspace.run!.reconcile();
    await until(() => requests.length == 2);
    expect(requests[1]['parent_id'], firstAssistant);
    expect(
      (requests[1]['messages'] as List)
          .where((m) => m['role'] == 'user')
          .map((m) => m['content']),
      ['First turn', 'Follow-up'],
    );
    expect(
      (requests[1]['messages'] as List)
          .where((m) => m['role'] == 'assistant')
          .single['content'],
      'Answer 1',
    );
    saved!['chat']['history']['messages'][requests[1]['id']]['done'] = true;
    taskActive = false;
    await until(() => workspace.run?.state == WebUiRunState.running);
    await workspace.run!.reconcile();
    await until(
      () =>
          workspace.queue.isEmpty &&
          workspace.conversation?.tip == requests[1]['id'],
    );
    workspace.setDraft('Keep this unsent thought');
    await workspace.flushDraft();
    offline = true;
    await workspace.open(null);
    workspace.setDraft('Different new draft');
    await workspace.flushDraft();
    await workspace.open('chat');
    expect(workspace.draft, 'Keep this unsent thought');
    expect(workspace.online, isFalse);
    expect(workspace.messages.map((m) => m.content), contains('Answer 2'));
    expect(requests, hasLength(2));
  });
}
