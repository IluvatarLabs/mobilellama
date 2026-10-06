import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/ollama/connection_options.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/run.dart';
import 'package:mobollama/open_webui/workspace.dart';

import '../support/chat_fixture.dart';

Future<void> until(bool Function() ready) async {
  for (var i = 0; !ready() && i < 300; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ready(), isTrue);
}

void main() {
  test('shared versions retain old paths and drafts; explicit continuation survives reopening and revision writes are additive', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    Map<String, dynamic> node(
      String id,
      String? parent,
      String role,
      String text,
      List<String> children,
    ) => {
      'id': id,
      'parentId': parent,
      'role': role,
      'content': text,
      'childrenIds': children,
      'done': true,
      'timestamp': 1,
    };
    final nodes = <String, dynamic>{
      'u0': node('u0', null, 'user', 'Original question', ['a0', 'b0']),
      'a0': node('a0', 'u0', 'assistant', 'Original answer', ['u1']),
      'u1': node('u1', 'a0', 'user', 'Original follow-up', ['a1']),
      'a1': node('a1', 'u1', 'assistant', 'Later answer', []),
      'b0': node('b0', 'u0', 'assistant', 'Alternative answer', []),
    };
    final originals = jsonDecode(jsonEncode(nodes)) as Map;
    var tip = 'a1', taskActive = false;
    final requests = <Map<String, dynamic>>[];
    final writes = <String>[];
    final client = OpenWebUiClient(
      baseUrl: 'http://127.0.0.1:1',
      options: ConnectionOptions(apiKey: 'token'),
      client: MockClient((request) async {
        final path = request.url.path;
        Object result;
        if (request.method != 'GET') writes.add(path);
        if (path == '/api/models') {
          result = {
            'data': [
              {'id': 'model'},
            ],
          };
        } else if (path == '/api/config') {
          result = {'features': {}};
        } else if (path == '/api/v1/chats/' ||
            path == '/api/v1/chats/archived') {
          result =
              path.endsWith('archived') ||
                  request.url.queryParameters['page'] != '1'
              ? []
              : [
                  {'id': 'chat', 'title': 'Versions'},
                ];
        } else if (path == '/api/v1/chats/chat' && request.method == 'GET') {
          result = {
            'id': 'chat',
            'user_id': 'user',
            'current_message_id': tip,
            'chat': {
              'title': 'Versions',
              'history': {'currentId': tip, 'messages': nodes},
            },
          };
        } else if (path == '/api/tasks/chat/chat') {
          result = {
            'task_ids': taskActive ? ['task'] : [],
          };
        } else if (path == '/api/chat/completions') {
          final body = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          requests.add(body);
          final user = Map<String, dynamic>.from(body['user_message'] as Map);
          if (user['id'] == 'u0') {
            // A desktop client adds a sibling after the app's preflight read.
            nodes['desktop'] = node(
              'desktop',
              'u0',
              'assistant',
              'Desktop version',
              [],
            );
            (nodes['u0']['childrenIds'] as List).add('desktop');
          }
          nodes[user['id'] as String] = {
            ...?nodes[user['id']] as Map?,
            ...user,
          };
          final parent = user['parentId'];
          if (parent != null) {
            final children = nodes[parent]['childrenIds'] as List;
            if (!children.contains(user['id'])) children.add(user['id']);
          }
          final children = nodes[user['id']]['childrenIds'] as List;
          if (!children.contains(body['id'])) children.add(body['id']);
          tip = body['id'] as String;
          nodes[tip] = {
            ...node(
              tip,
              user['id'] as String,
              'assistant',
              'New answer ${requests.length}',
              [],
            ),
            'done': false,
          };
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
      'profile',
      WebUiIdentity(
        server: client.serverId,
        userId: 'user',
        name: 'User',
        permissions: {},
      ),
      client,
    );
    await f.store.webUi.unlock(session.capture());
    final w = WebUiWorkspace(
      WebUiAccounts(f.settings, ProfileCredentials(f.secrets), f.store.webUi),
      session,
    );
    addTearDown(w.dispose);
    await w.initialize();
    await w.open('chat');
    w.setDraft('Continue the alternative');
    w.viewVersion('b0');
    expect(w.previewingVersion, isTrue);
    expect(w.canSend, isFalse);
    expect(w.messages.last.content, 'Alternative answer');
    expect(writes, isEmpty);
    await w.continueViewedVersion();
    expect(w.expectedParent, 'b0');
    expect(w.diverged, isFalse);
    await w.open(null);
    await w.open('chat');
    expect(w.draft, 'Continue the alternative');
    expect(w.continuationTip, 'b0');
    expect(w.messages.last.id, 'b0');
    expect(writes, isEmpty);

    Future<void> settle() async {
      await until(() => w.run?.state == WebUiRunState.running);
      taskActive = false;
      nodes[tip]['done'] = true;
      await w.run!.reconcile();
      await until(() => w.conversation?.tip == tip && !w.busy);
    }

    expect(await w.send(w.draft), isTrue);
    await settle();
    expect(requests.single['parent_id'], 'b0');
    expect((requests.single['messages'] as List).map((m) => m['content']), [
      'Original question',
      'Alternative answer',
      'Continue the alternative',
    ]);

    w.setDraft('Keep my unsent next thought');
    await w.flushDraft();
    w.viewVersion('a0');
    expect(w.messages.last.id, 'a1');
    expect(await w.revise('a0'), isTrue);
    await settle();
    final regenerated = tip;
    expect(requests[1]['user_message']['id'], 'u0');
    expect(
      (requests[1]['user_message'] as Map).containsKey('childrenIds'),
      isFalse,
    );
    expect(requests[1]['user_message']['timestamp'], 1);
    expect((requests[1]['messages'] as List).map((m) => m['content']), [
      'Original question',
    ]);
    expect(w.draft, 'Keep my unsent next thought');
    expect(w.diverged, isTrue);
    expect(w.versionsOf('a0'), ['a0', 'b0', 'desktop', regenerated]);
    for (final id in originals.keys) {
      expect(nodes[id]['content'], originals[id]['content']);
      expect(nodes[id]['parentId'], originals[id]['parentId']);
    }
    expect(w.messages.last.id, regenerated);

    w.viewVersion('a0');
    await w.continueViewedVersion();
    expect(w.expectedParent, 'a1');
    expect(w.diverged, isFalse);
    expect(await w.send(w.draft), isTrue);
    await settle();
    expect(requests[2]['parent_id'], 'a1');
    expect((requests[2]['messages'] as List).map((m) => m['content']), [
      'Original question',
      'Original answer',
      'Original follow-up',
      'Later answer',
      'Keep my unsent next thought',
    ]);
    expect(await w.revise('u0', text: 'Edited root question'), isTrue);
    await settle();
    expect(requests[3]['user_message']['id'], isNot('u0'));
    expect(requests[3]['user_message']['parentId'], isNull);
    expect(nodes['u0']['content'], 'Original question');
    expect((requests[3]['messages'] as List).map((m) => m['content']), [
      'Edited root question',
    ]);
    expect(
      w.versionsOf(requests[3]['user_message']['id'] as String),
      hasLength(2),
    );
    expect(writes, everyElement('/api/chat/completions'));
    await w.open(null);
    await w.open('chat');
    w.viewVersion('a0');
    expect(w.messages.map((m) => m.content), contains('Later answer'));
    expect(nodes.containsKey(regenerated), isTrue);
  });
}
