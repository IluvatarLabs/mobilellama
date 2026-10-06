import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/ollama/connection_options.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/folders.dart';
import 'package:mobollama/open_webui/workspace.dart';

import '../support/chat_fixture.dart';

void main() {
  test('server folders retain existing data; a selected new-chat folder is durable and deletion keeps chats', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    final folder = <String, dynamic>{
      'id': 'folder',
      'name': 'Research',
      'parent_id': null,
      'user_id': 'user',
      'write_access': true,
      'data': <String, dynamic>{
        'system_prompt': 'Use sources.',
        'files': [
          {'id': 'retained-file'},
        ],
      },
    };
    Map<String, dynamic>? saved;
    Map? creation;
    final client = OpenWebUiClient(
      baseUrl: 'http://127.0.0.1:1',
      options: ConnectionOptions(apiKey: 'token'),
      client: MockClient((request) async {
        final path = request.url.path;
        final body = request.body.isEmpty
            ? null
            : jsonDecode(request.body) as Map;
        Object result;
        if (path == '/api/config') {
          result = {
            'features': {'enable_folders': true},
          };
        } else if (path == '/api/models') {
          result = {
            'data': [
              {'id': 'model'},
            ],
          };
        } else if (path == '/api/v1/folders/shared') {
          result = [
            {
              'id': 'shared',
              'name': 'Team',
              'permission': 'read',
              'user_id': 'other',
            },
          ];
        } else if (path == '/api/v1/folders/') {
          result = [folder];
        } else if (path == '/api/v1/folders/folder/update') {
          expect((body!['data'] as Map).keys, ['system_prompt']);
          folder['name'] = body['name'];
          (folder['data'] as Map).addAll(body['data'] as Map);
          result = folder;
        } else if (path == '/api/v1/folders/folder/update/parent') {
          folder['parent_id'] = body!['parent_id'];
          result = folder;
        } else if (path == '/api/v1/folders/folder' &&
            request.method == 'DELETE') {
          expect(request.url.queryParameters['delete_contents'], 'false');
          saved!['folder_id'] = null;
          result = true;
        } else if (path == '/api/v1/folders/folder') {
          result = folder;
        } else if (path == '/api/v1/chats/folder/folder/list') {
          final page = int.parse(request.url.queryParameters['page']!);
          result = List.generate(
            page == 1 ? 10 : 1,
            (i) => {'id': 'chat-${(page - 1) * 10 + i}', 'title': 'Chat'},
          );
        } else if (path == '/api/v1/folders/shared/shared/chats') {
          result = {
            'chats': [
              {'id': 'shared-chat', 'readonly': true},
            ],
            'has_more': false,
          };
        } else if (path == '/api/v1/chats/' ||
            path == '/api/v1/chats/archived') {
          result = [];
        } else if (path == '/api/v1/chats/new') {
          creation = body;
          saved = {
            'id': 'chat',
            'user_id': 'user',
            'chat': body!['chat'],
            'folder_id': body['folder_id'],
            'pinned': false,
          };
          result = saved!;
        } else if (path == '/api/v1/chats/chat/folder') {
          saved!['folder_id'] = body!['folder_id'];
          saved!['pinned'] = false;
          result = saved!;
        } else if (path == '/api/chat/completions') {
          final history = saved!['chat']['history'] as Map;
          final user = body!['user_message'] as Map;
          history['messages'][body['id']] = {
            'id': body['id'],
            'parentId': user['id'],
            'role': 'assistant',
            'content': 'Answer using folder context',
            'done': true,
          };
          history['currentId'] = body['id'];
          result = {'status': true, 'chat_id': 'chat', 'task_ids': []};
        } else if (path == '/api/v1/chats/chat') {
          result = saved!;
        } else if (path == '/api/tasks/chat/chat') {
          result = {'task_ids': []};
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
    final folders = WebUiFolders(session);
    final w = WebUiWorkspace(
      WebUiAccounts(f.settings, ProfileCredentials(f.secrets), f.store.webUi),
      session,
    );
    addTearDown(w.dispose);
    await w.initialize();
    expect(await folders.list(), hasLength(2));
    await folders.save(
      id: 'folder',
      name: 'Edited research',
      instructions: 'Be concise.',
    );
    expect((await folders.get('folder'))['data'], {
      'system_prompt': 'Be concise.',
      'files': [
        {'id': 'retained-file'},
      ],
    });
    await folders.move('folder', 'parent');
    expect(folder['parent_id'], 'parent');
    expect((await folders.chats(folder, 1)).more, isTrue);
    expect((await folders.chats(folder, 2)).chats, hasLength(1));
    expect(
      (await folders.chats({
        'id': 'shared',
        'user_id': 'other',
      }, 1)).chats.single['readonly'],
      isTrue,
    );
    await w.setDraftFolder('folder', 'Edited research');
    w.setDraft('A folder question');
    await w.open(null);
    expect(w.resources['folderId'], 'folder');
    expect(w.draft, 'A folder question');
    expect(await w.send(w.draft), isTrue);
    for (var i = 0; w.conversation == null && i < 300; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(w.conversation, isNotNull);
    expect(creation!['folder_id'], 'folder');
    expect((creation!['chat'] as Map).containsKey('folder_id'), isFalse);
    final historyBefore = jsonEncode(saved!['chat']);
    await folders.moveChat('chat', null);
    await folders.deleteKeepingChats('folder');
    expect(saved!['folder_id'], isNull);
    expect(jsonEncode(saved!['chat']), historyBefore);
    await w.open(null);
    await w.setDraftFolder(null, null);
    expect(w.resources.containsKey('folderId'), isFalse);
  });
}
