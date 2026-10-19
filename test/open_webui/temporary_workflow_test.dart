import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/socket.dart';
import 'package:mobollama/open_webui/temporary.dart';
import 'package:mobollama/ollama/connection_options.dart';

import '../support/chat_fixture.dart';

class _Socket extends WebUiSocket {
  _Socket(super.session);
  final feed = StreamController<WebUiEvent>.broadcast(sync: true);
  final connectionFeed = StreamController<bool>.broadcast(sync: true);
  @override
  String? sessionId = 'verified-session';
  @override
  Stream<WebUiEvent> get events => feed.stream;
  @override
  Stream<bool> get connections => connectionFeed.stream;
  @override
  Future<void> connect() async {}
  @override
  void configureHeartbeat(Object? seconds) {}
  @override
  void dispose() {
    unawaited(feed.close());
    unawaited(connectionFeed.close());
  }
}

void main() {
  test('temporary socket output includes outlet edits, queue stays in memory, and explicit Save writes once', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    final requests = <Map<String, dynamic>>[];
    Map<String, dynamic>? saved;
    var creates = 0;
    final client = OpenWebUiClient(
      baseUrl: 'https://web.test/prefix',
      options: ConnectionOptions(apiKey: 'token'),
      client: MockClient((request) async {
        Object result;
        if (request.url.path == '/prefix/api/chat/completions') {
          final data = Map<String, dynamic>.from(
            jsonDecode(request.body) as Map,
          );
          requests.add(data);
          result = {
            'status': true,
            'chat_id': data['chat_id'],
            'task_ids': ['task'],
          };
        } else if (request.url.path == '/prefix/api/v1/chats/new') {
          creates++;
          result = saved = {
            'id': 'saved',
            'chat': jsonDecode(request.body)['chat'],
          };
        } else if (request.url.path == '/prefix/api/v1/chats/saved') {
          result = saved!;
        } else {
          throw StateError(
            'Temporary chat unexpectedly called ${request.url.path}',
          );
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
    final socket = _Socket(session);
    final temp = WebUiTemporaryChat(session, socket, model: 'model');
    addTearDown(temp.dispose);
    await temp.initialize();
    await temp.send('First question');
    final first = requests.single;
    expect(first['chat_id'], 'temporary:verified-session');
    expect(first['session_id'], 'verified-session');
    expect(first['tools'], isEmpty);
    expect((first['features'] as Map).values.every((v) => v == false), isTrue);
    expect(first.containsKey('files'), isFalse);
    void event(String type, Object data) => socket.feed.add(
      WebUiEvent(temp.chatId, requests.last['id'] as String, type, data, null),
    );
    event('response:completion', {
      'type': 'response.output_text.delta',
      'delta': 'Initial answer',
    });
    expect(temp.messages.last.content, 'Initial answer');
    await temp.send('Queued question');
    temp.setForeground(false);
    final output = [
      {
        'type': 'message',
        'content': [
          {'type': 'output_text', 'text': 'Initial answer'},
        ],
      },
    ];
    event('chat:completion', {'done': true, 'output': output});
    expect(temp.running, isTrue);
    event('chat:outlet', {
      'messages': [
        {'id': first['id'], 'content': 'Final outlet answer', 'output': output},
      ],
    });
    event('chat:active', {'active': false});
    expect(temp.messages.last.content, 'Final outlet answer');
    expect(requests.length, 1);
    temp.setForeground(true);
    temp.resumeQueue();
    for (var i = 0; requests.length < 2 && i < 100; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(requests.length, 2);
    expect(
      requests.last['messages'].toString(),
      contains('Final outlet answer'),
    );
    expect(
      requests.last['messages'].toString(),
      isNot(contains('Initial answer')),
    );
    event('response:completion', {
      'type': 'response.output_text.delta',
      'delta': 'Useful partial',
    });
    socket.sessionId = null;
    socket.connectionFeed.add(false);
    expect(temp.canSend, isFalse);
    expect(temp.messages.last.content, 'Useful partial');
    expect(await f.store.webUi.intents(session.capture()), isEmpty);
    expect(await f.store.loadDrafts(), isEmpty);
    expect(await f.store.webUi.chats(session.capture()), isEmpty);
    expect(await f.store.webUi.queue(session.capture(), temp.chatId!), isEmpty);
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    temp.setDraft('Retain this unsent question');
    final accounts = WebUiAccounts(
      f.settings,
      ProfileCredentials(f.secrets),
      f.store.webUi,
    );
    await temp.save(accounts);
    await temp.save(accounts);
    expect(creates, 1);
    expect(
      (await f.store.webUi.draft(session.capture(), 'saved'))!['text'],
      'Retain this unsent question',
    );
    expect(saved.toString(), contains('Useful partial'));
    expect(saved.toString(), contains('Final outlet answer'));
  });
}
