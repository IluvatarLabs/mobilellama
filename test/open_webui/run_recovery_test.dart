import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/ollama/connection_options.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/run.dart';

import '../support/chat_fixture.dart';

void main() {
  for (final loseAcknowledgment in [false, true]) {
    test(
      'saved run recovery ${loseAcknowledgment ? 'after lost acknowledgment' : 'after late outlet'} never dispatches twice',
      () async {
        final fixture = ChatFixture();
        await fixture.open();
        addTearDown(fixture.close);
        var completionCount = 0;
        var taskRunning = false;
        final nodes = <String, dynamic>{
          'prior': {
            'id': 'prior',
            'parentId': null,
            'role': 'assistant',
            'content': 'Earlier answer',
            'done': true,
          },
        };
        String tip = 'prior';
        final client = OpenWebUiClient(
          baseUrl: 'https://server.test/team',
          options: ConnectionOptions(apiKey: 'secret'),
          client: MockClient((request) async {
            Object? result;
            switch (request.url.path) {
              case '/team/api/v1/chats/chat':
                result = {
                  'id': 'chat',
                  'chat': {
                    'history': {'currentId': tip, 'messages': nodes},
                  },
                };
              case '/team/api/tasks/chat/chat':
                result = {
                  'task_ids': taskRunning ? ['task'] : [],
                };
              case '/team/api/chat/completions':
                completionCount++;
                final body = jsonDecode(request.body) as Map;
                expect(body['parent_id'], 'prior');
                expect(body.containsKey('tools'), isFalse);
                expect((body['messages'] as List).map((m) => m['content']), [
                  'Earlier answer',
                  'Continue',
                ]);
                expect(body['background_tasks'], {
                  'title_generation': false,
                  'tags_generation': false,
                  'follow_up_generation': false,
                });
                final user = body['user_message'] as Map;
                nodes[user['id'] as String] = user;
                tip = body['id'] as String;
                nodes[tip] = {
                  'id': tip,
                  'parentId': user['id'],
                  'role': 'assistant',
                  'content': 'Before outlet',
                  'done': true,
                };
                taskRunning = !loseAcknowledgment;
                if (loseAcknowledgment) {
                  throw const SocketException('Acknowledgment lost');
                }
                result = {
                  'status': true,
                  'chat_id': 'chat',
                  'task_ids': ['task'],
                };
              default:
                fail('Unexpected request ${request.method} ${request.url}');
            }
            return http.Response(
              jsonEncode(result),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        addTearDown(client.close);
        final session = WebUiSession(
          'profile',
          WebUiIdentity(
            server: client.serverId,
            userId: 'account',
            name: 'Account',
            permissions: {},
          ),
          client,
        );
        final store = fixture.store.webUi;
        await store.unlock(session.capture());
        final run = await WebUiRun.prepare(
          session: session,
          store: store,
          chatId: 'chat',
          expectedParentId: 'prior',
          text: 'Continue',
          model: 'model',
        );
        expect(
          (await store.intents(session.capture())).single['state'],
          'prepared',
        );
        await run.dispatch();
        expect(
          run.state,
          loseAcknowledgment ? WebUiRunState.uncertain : WebUiRunState.running,
        );
        expect(completionCount, 1);
        nodes[tip] = {
          ...nodes[tip] as Map,
          'content': 'Authoritative outlet answer',
        };
        taskRunning = false;
        run.dispose();
        final recovered = await WebUiRun.restore(
          session,
          store,
          null,
          (await store.intents(session.capture())).single,
        );
        addTearDown(recovered.dispose);
        await recovered.reconcile();
        expect(recovered.state, WebUiRunState.completed);
        expect(recovered.partial, 'Authoritative outlet answer');
        expect(completionCount, 1);
        final cached = await store.chat(session.capture(), 'chat');
        expect(
          (cached!['chat'] as Map)['history']['messages'][tip]['content'],
          'Authoritative outlet answer',
        );
      },
    );
  }

  test('lost new-chat acknowledgment locates stable user ID without creating or generating again', () async {
    final fixture = ChatFixture();
    await fixture.open();
    addTearDown(fixture.close);
    var creates = 0;
    Map<String, dynamic>? saved;
    final client = OpenWebUiClient(
      baseUrl: 'https://server.test',
      options: ConnectionOptions(apiKey: 'secret'),
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/chats/new') {
          creates++;
          saved = {'id': 'created', 'chat': jsonDecode(request.body)['chat']};
          throw const SocketException('Creation acknowledgment lost');
        }
        final Object result;
        if (request.url.path == '/api/v1/chats/') {
          result = [
            {'id': 'created'},
          ];
        } else if (request.url.path == '/api/v1/chats/created') {
          result = saved!;
        } else if (request.url.path == '/api/tasks/chat/created') {
          result = {'task_ids': []};
        } else {
          fail(
            'No completion or second creation is authorized: ${request.url}',
          );
        }
        return http.Response(jsonEncode(result), 200);
      }),
    );
    addTearDown(client.close);
    final session = WebUiSession(
      'profile',
      WebUiIdentity(
        server: client.serverId,
        userId: 'account',
        name: 'Account',
        permissions: {},
      ),
      client,
    );
    await fixture.store.webUi.unlock(session.capture());
    final run = await WebUiRun.prepare(
      session: session,
      store: fixture.store.webUi,
      expectedParentId: null,
      text: 'New question',
      model: 'model',
    );
    addTearDown(run.dispose);
    await fixture.store.webUi.saveDraft(session.capture(), 'new:profile', {
      'text': 'A follow-up drafted before the creation reply',
      'parentId': run.assistantId,
      'resources': {
        'skill_ids': ['selected-skill'],
      },
    });
    await run.dispatch();
    expect(run.state, WebUiRunState.uncertain);
    expect(run.chatId, isNull);
    await run.locateCreatedChat();
    expect(run.chatId, 'created');
    expect(run.state, WebUiRunState.uncertain);
    expect(creates, 1);
    expect(
      await fixture.store.webUi.draft(session.capture(), 'new:profile'),
      isNull,
    );
    final adopted = await fixture.store.webUi.draft(
      session.capture(),
      'created',
    );
    expect(adopted?['text'], 'A follow-up drafted before the creation reply');
    expect(adopted?['parentId'], run.assistantId);
    expect(adopted?['resources'], {
      'skill_ids': ['selected-skill'],
    });
  });
}
