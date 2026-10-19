import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/ollama/connection_options.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/workspace.dart';
import 'package:mobollama/data/profile_credentials.dart';

import '../support/chat_fixture.dart';

void main() {
  test('expired account stays bound until explicit local sign-out, and complete inventory removes only confirmed missing cache', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    var failSecondPage = true;
    final client = OpenWebUiClient(
      baseUrl: 'https://server.test',
      options: ConnectionOptions(apiKey: 'expired'),
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/chats/' &&
            request.url.queryParameters['page'] == '1') {
          return http.Response('[{"id":"kept","title":"Kept"}]', 200);
        }
        if (request.url.path == '/api/v1/chats/' && failSecondPage) {
          return http.Response('temporarily unavailable', 503);
        }
        return http.Response('[]', 200);
      }),
    );
    addTearDown(client.close);
    WebUiSession account(String id) => WebUiSession(
      'saved-profile',
      WebUiIdentity(
        server: client.serverId,
        userId: id,
        name: id,
        permissions: {},
      ),
      client,
    );
    final a = account('A');
    final b = account('B');
    final store = f.store.webUi;
    await store.unlock(a.capture());
    await store.saveDraft(a.capture(), 'draft', {'text': 'Account A draft'});
    for (final id in ['kept', 'deleted', 'draft']) {
      await store.cacheChat(a.capture(), {
        'id': id,
        'chat': {
          'history': {'currentId': null, 'messages': {}},
        },
      });
    }
    final workspace = WebUiWorkspace(
      WebUiAccounts(f.settings, ProfileCredentials(f.secrets), store),
      a,
    );
    addTearDown(workspace.dispose);
    await workspace.synchronizeInventory();
    expect(
      (await store.chats(a.capture())).map((item) => item['id']),
      unorderedEquals(['kept', 'deleted', 'draft']),
    );
    expect(
      (await store.draft(a.capture(), 'draft'))!['text'],
      'Account A draft',
    );
    failSecondPage = false;
    await workspace.synchronizeInventory();
    expect(
      (await store.chats(a.capture())).map((item) => item['id']),
      unorderedEquals(['kept', 'draft']),
    );
    expect(
      (await store.chat(a.capture(), 'draft'))!['missingOnServer'],
      isTrue,
    );
    a.lock();
    expect((await store.binding('saved-profile'))!['user_id'], 'A');
    await expectLater(
      store.unlock(b.capture()),
      throwsA(isA<WebUiException>()),
    );
    await store.clearStoredAccount('saved-profile');
    await store.unlock(b.capture());
    expect(await store.draft(b.capture(), 'draft'), isNull);
    expect(await store.chats(b.capture()), isEmpty);
  });

  test('account switch fences a late history response and remote caches never enter direct backups', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.seed('direct');
    await f.controller.initialize();
    final pending = Completer<http.Response>();
    final dispatched = Completer<void>();
    final client = OpenWebUiClient(
      baseUrl: 'https://server.test/prefix',
      options: ConnectionOptions(apiKey: 'account-a-secret'),
      client: MockClient((request) async {
        expect(request.url.path, '/prefix/api/v1/chats/private');
        expect(request.headers['authorization'], 'Bearer account-a-secret');
        dispatched.complete();
        return pending.future;
      }),
    );
    addTearDown(client.close);
    WebUiSession session(String user) => WebUiSession(
      'profile',
      WebUiIdentity(
        server: client.serverId,
        userId: user,
        name: user,
        permissions: {},
      ),
      client,
    );
    final a = session('A');
    final b = session('B');
    final cache = f.store.webUi;
    await cache.unlock(a.capture());
    await cache.saveDraft(a.capture(), 'private', {'text': 'Private draft A'});
    final refresh = cache.refreshChat(a, 'private');
    final rejected = expectLater(refresh, throwsA(isA<WebUiException>()));
    await dispatched.future;
    await cache.signOut(a);
    await cache.unlock(b.capture());
    await cache.saveDraft(b.capture(), 'private', {'text': 'Draft B'});
    pending.complete(
      http.Response(
        jsonEncode({
          'id': 'private',
          'chat': {
            'history': {
              'currentId': 'm1',
              'messages': {
                'm1': {
                  'id': 'm1',
                  'role': 'assistant',
                  'content': 'Private answer A',
                },
              },
            },
          },
        }),
        200,
      ),
    );
    await rejected;
    expect(await cache.chats(b.capture()), isEmpty);
    expect((await cache.draft(b.capture(), 'private'))!['text'], 'Draft B');
    final backup = await f.controller.exportBackup();
    expect(backup, contains('Previously saved answer'));
    expect(backup, isNot(contains('Private')));
    expect(backup, isNot(contains('Draft B')));
    expect(backup, isNot(contains('account-a-secret')));
    expect(
      await f.database.rawQuery(
        "SELECT * FROM remote_drafts WHERE user_id='A'",
      ),
      isEmpty,
    );
  });
}
