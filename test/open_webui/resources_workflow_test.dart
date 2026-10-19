import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/files.dart';
import 'package:mobollama/open_webui/resources.dart';
import 'package:mobollama/open_webui/workspace.dart';
import 'package:mobollama/ollama/connection_options.dart';

import '../support/chat_fixture.dart';

void main() {
  test('processing failure preserves the question; retry reuses the upload and selections survive reopening', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    final directory = await Directory.systemTemp.createTemp(
      'mobilellama-upload-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final requests = <http.Request>[];
    var prepared = false;
    final client = OpenWebUiClient(
      baseUrl: 'http://127.0.0.1:1/prefix',
      options: ConnectionOptions(apiKey: 'account-a'),
      client: MockClient((r) async {
        requests.add(r);
        Object value;
        switch (r.url.path) {
          case '/prefix/api/v1/files/':
            expect(
              r.headers['content-type'],
              startsWith('multipart/form-data'),
            );
            value = {'id': 'uploaded', 'filename': 'Question.txt'};
          case '/prefix/api/v1/files/uploaded/process/status':
            value = {'status': prepared ? 'completed' : 'failed'};
          case '/prefix/api/v1/retrieval/process/file':
            prepared = true;
            value = {'status': true};
          case '/prefix/api/v1/chats/':
          case '/prefix/api/v1/chats/archived':
            value = [];
          case '/prefix/api/models':
            value = {
              'data': [
                {'id': 'model'},
                {
                  'id': 'text-only',
                  'info': {
                    'meta': {
                      'capabilities': {
                        'web_search': false,
                        'file_upload': false,
                      },
                    },
                  },
                },
              ],
            };
          case '/prefix/api/config':
            value = {
              'features': {'enable_web_search': true},
            };
          default:
            throw StateError(r.url.path);
        }
        return http.Response(jsonEncode(value), 200);
      }),
    );
    final session = WebUiSession(
      'account-a',
      WebUiIdentity(
        server: client.serverId,
        userId: 'a',
        name: 'A',
        permissions: {
          'features': {'web_search': true},
        },
      ),
      client,
    );
    await f.store.webUi.unlock(session.capture());
    final w = WebUiWorkspace(
      WebUiAccounts(f.settings, ProfileCredentials(f.secrets), f.store.webUi),
      session,
      files: WebUiFiles(directory),
    );
    addTearDown(w.dispose);
    await w.initialize();
    expect(w.uploadsAvailable, isTrue);
    await w.setFeature('web_search', true);
    await w.selectModel('text-only');
    expect(w.uploadsAvailable, isFalse);
    expect((w.resources['features'] as Map)['web_search'], isFalse);
    await w.selectModel('model');
    w.setDraft('What does the document say?');
    await w.addFile('Question.txt', utf8.encode('The deadline is Friday.'));
    for (var n = 0; n < 200 && w.uploads.single['state'] != 'failed'; n++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(w.uploads.single['state'], 'failed');
    expect(w.draft, 'What does the document say?');
    expect(w.canSend, isFalse);
    await w.uploadFile(w.uploads.single);
    expect(w.uploads.single['state'], 'ready');
    expect(w.canSend, isTrue);
    await w.setResource(WebUiResourceKind.skills, {
      'id': 'explain',
      'is_active': true,
    }, true);
    await w.setResource(WebUiResourceKind.knowledge, {
      'id': 'manual',
      'name': 'Manual',
    }, true);
    await w.open(null);
    expect(w.draft, 'What does the document say?');
    expect(w.resources['skill_ids'], ['explain']);
    expect((w.resources['files'] as List).map((f) => f['id']), [
      'uploaded',
      'manual',
    ]);
    expect(
      requests.where(
        (r) => r.method == 'POST' && r.url.path.endsWith('/files/'),
      ),
      hasLength(1),
    );
    expect(requests.where((r) => r.url.path.endsWith('/completions')), isEmpty);
    expect(
      WebUiResources.sources({
        'sources': [
          {
            'source': {'id': 'uploaded', 'type': 'file', 'name': 'Question'},
            'metadata': [
              {'file_id': 'uploaded', 'source': 'https://private.test/secret'},
            ],
            'document': ['Friday'],
          },
        ],
        'output': [
          {
            'type': 'message',
            'content': [
              {
                'type': 'output_text',
                'annotations': [
                  {'type': 'file_citation', 'file_id': 'uploaded'},
                ],
              },
            ],
          },
        ],
      }).single.url,
      isNull,
    );
  });

  test('authenticated image bytes stay within the account and late bytes cannot appear after sign-out', () async {
    final started = Completer<void>(), release = Completer<void>();
    final urls = <Uri>[];
    final client = OpenWebUiClient(
      baseUrl: 'https://server.test/team',
      options: ConnectionOptions(apiKey: 'a-token'),
      client: MockClient((r) async {
        urls.add(r.url);
        expect(r.headers['authorization'], 'Bearer a-token');
        if (r.url.path.endsWith('/late/content')) {
          started.complete();
          await release.future;
        }
        return http.Response.bytes([1, 2, 3], 200);
      }),
    );
    addTearDown(client.close);
    final a = WebUiSession(
      'a',
      WebUiIdentity(
        server: client.serverId,
        userId: 'a',
        name: 'A',
        permissions: {},
      ),
      client,
    );
    expect(await client.fileBytes('/api/v1/files/image/content', a.capture()), [
      1,
      2,
      3,
    ]);
    expect(urls.single.path, '/team/api/v1/files/image/content');
    for (final url in [
      'https://elsewhere.test/api/v1/files/image/content',
      'https://server.test/outside/api/v1/files/image/content',
      '/api/v1/files/image/content?token=secret',
    ]) {
      await expectLater(
        client.fileBytes(url, a.capture()),
        throwsA(isA<WebUiException>()),
      );
    }
    expect(
      urls,
      hasLength(1),
    ); // No credential-bearing request reached those destinations.
    final future = client.fileBytes(
      '/team/api/v1/files/late/content',
      a.capture(),
    );
    final rejected = expectLater(future, throwsA(isA<WebUiException>()));
    await started.future;
    a.lock();
    release.complete();
    await rejected;
    expect(urls, hasLength(2));
  });
}
