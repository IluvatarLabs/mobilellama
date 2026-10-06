import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/export.dart';
import 'package:mobollama/ollama/connection_options.dart';

import '../support/chat_fixture.dart';

void main() {
  test('account A portable branch imports under an explicit direct destination while B stays untouched', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    final calls = <String>[];
    final client = OpenWebUiClient(
      baseUrl: 'https://a.test',
      options: ConnectionOptions(apiKey: 'secret-a'),
      client: MockClient((r) async {
        calls.add('${r.method} ${r.url.path}');
        return http.Response(
          jsonEncode({
            'id': 'remote-chat',
            'chat': {
              'title': 'Shared research',
              'history': {
                'currentId': 'remote-answer',
                'messages': {
                  'remote-question': {
                    'id': 'remote-question',
                    'role': 'user',
                    'parentId': null,
                    'content': 'Explain the report',
                  },
                  'remote-answer': {
                    'id': 'remote-answer',
                    'parentId': 'remote-question',
                    'role': 'assistant',
                    'content': 'It is Friday. [Private report](https://a.test/api/v1/files/private-file/content)',
                    'done': true,
                    'sources': [
                      {
                        'source': {
                          'type': 'file',
                          'id': 'private-file',
                          'name': 'Report',
                        },
                      },
                    ],
                  },
                },
              },
            },
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);
    final a = WebUiSession(
      'a',
      WebUiIdentity(
        server: client.serverId,
        userId: 'account-a',
        name: 'A',
        permissions: {},
      ),
      client,
    );
    await f.store.webUi.unlock(a.capture());
    final exporter = WebUiExport(a, f.store.webUi);
    final branch = await exporter.completeBranch('remote-chat');
    final portable = exporter.portableJson(branch);
    for (final secret in [
      'secret-a',
      'remote-chat',
      'remote-question',
      'remote-answer',
      'private-file',
      'account-a',
      'https://a.test',
    ]) {
      expect(portable, isNot(contains(secret)));
    }
    await f.store.webUi.signOut(a);
    final b = WebUiSession(
      'b',
      WebUiIdentity(
        server: client.serverId,
        userId: 'account-b',
        name: 'B',
        permissions: {},
      ),
      client,
    );
    await f.store.webUi.unlock(b.capture());
    final directRequests = f.requests.length;
    expect(
      await f.controller.importBackup(portable, localDestinationId: 'home'),
      1,
    );
    final chats = await f.store.listAllConversations();
    final local = chats.single;
    expect(local.serverProfileId, 'home');
    expect(local.id, isNot('remote-chat'));
    final thread = await f.store.openConversation(
      serverProfileId: 'home',
      id: local.id,
    );
    expect(
      thread!.messages.map((m) => m.content).join('\n'),
      contains('account-bound source unavailable'),
    );
    expect(
      thread.messages.every(
        (m) =>
            m.providerTranscriptJson == null &&
            m.toolCalls.isEmpty &&
            m.toolResults.isEmpty,
      ),
      isTrue,
    );
    expect(await f.store.webUi.chats(b.capture()), isEmpty);
    expect(calls, ['GET /api/v1/chats/remote-chat']);
    expect(f.requests.length, directRequests);
    final backup = await f.controller.exportBackup();
    expect(backup, contains('local copy'));
    expect(backup, isNot(contains('"account-b"')));
  });
}
