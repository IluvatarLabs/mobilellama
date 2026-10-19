import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/conversation.dart';
import 'package:mobollama/domain/document_attachment.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/tool_call.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite;

void main() {
  setUpAll(sqflite.sqfliteFfiInit);

  test('conversation create, context update, and delete stay scoped by profile and id', () async {
    final database = RecordingDatabase(
      onQuery: (sql, _) async => sql.startsWith('SELECT 1 FROM conversations')
          ? <Map<String, Object?>>[
              <String, Object?>{'1': 1},
            ]
          : const <Map<String, Object?>>[],
    );
    final store = ConversationStore(database);
    final now = DateTime.utc(2026, 8, 29, 12);

    final created = await store.createConversation(
      id: 'conversation-1',
      serverProfileId: 'profile-1',
      selectedModel: 'qwen3:4b',
      systemPrompt: 'Be concise.',
      now: now,
    );
    await store.updateConversationContext(
      id: created.id,
      selectedModel: 'gpt-oss:20b',
      systemPrompt: 'Use tools when needed.',
      now: now.add(const Duration(minutes: 1)),
    );
    await store.deleteConversation(
      serverProfileId: 'profile-1',
      id: created.id,
    );

    expect(created.serverProfileId, 'profile-1');
    expect(created.title, 'New chat');
    expect(created.selectedModel, 'qwen3:4b');
    expect(
      database.executions.any(
        (entry) =>
            entry.sql.startsWith('INSERT INTO conversations') &&
            entry.parameters[0] == 'conversation-1' &&
            entry.parameters[1] == 'profile-1' &&
            entry.parameters[3] == 'qwen3:4b' &&
            entry.parameters[4] == 'Be concise.',
      ),
      isTrue,
    );
    expect(
      database.executions.any(
        (entry) =>
            entry.sql.startsWith('UPDATE conversations') &&
            entry.sql.contains('selected_model = ?') &&
            entry.parameters[0] == 'gpt-oss:20b' &&
            entry.parameters.last == 'conversation-1',
      ),
      isTrue,
    );
    expect(
      database.executions.any(
        (entry) =>
            entry.sql ==
                'DELETE FROM conversations WHERE server_profile_id = ? AND id = ?' &&
            entry.parameters[0] == 'profile-1' &&
            entry.parameters[1] == 'conversation-1',
      ),
      isTrue,
    );
  });

  test(
    'append and interruption update retain the complete agent payload',
    () async {
      var nextPosition = 0;
      final database = RecordingDatabase(
        onQuery: (sql, parameters) async {
          if (sql.contains('next_position')) {
            return <Map<String, Object?>>[
              <String, Object?>{'next_position': nextPosition++},
            ];
          }
          return const <Map<String, Object?>>[];
        },
      );
      final store = ConversationStore(database);
      final now = DateTime.utc(2026, 8, 29, 12);

      await store.appendMessage(
        id: 'user-1',
        conversationId: 'conversation-1',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: '  Explain\n deterministic   ordering  ',
        imageReferences: const <String>['image://one'],
        now: now,
      );
      final assistant = await store.appendMessage(
        id: 'assistant-1',
        conversationId: 'conversation-1',
        role: MessageRole.assistant,
        status: MessageStatus.streaming,
        content: 'First partial chunk',
        reasoning: 'internal trace',
        toolCalls: const <ToolCall>[
          ToolCall(
            id: 'call-1',
            name: 'search',
            arguments: <String, Object?>{'query': 'ordering'},
          ),
        ],
        toolResults: const <ToolResult>[
          ToolResult(
            id: 'result-1',
            toolCallId: 'call-1',
            content: 'result text',
          ),
        ],
        now: now.add(const Duration(seconds: 1)),
      );
      await store.updateMessage(
        assistant.copyWith(
          status: MessageStatus.interrupted,
          content: 'First partial chunk, preserved.',
          updatedAt: now.add(const Duration(seconds: 2)),
        ),
      );

      final titleUpdate = database.executions.firstWhere(
        (entry) => entry.sql.contains('title_from_first_user = 1'),
      );
      expect(titleUpdate.parameters.first, 'Explain deterministic ordering');

      final messageUpdate = database.executions.firstWhere(
        (entry) => entry.sql.contains('SET status = ?'),
      );
      expect(messageUpdate.parameters[0], MessageStatus.interrupted.name);
      expect(messageUpdate.parameters[1], 'First partial chunk, preserved.');
      expect(messageUpdate.parameters[2], 'internal trace');

      expect(
        database.executions.any(
          (entry) =>
              entry.sql.contains('INSERT INTO message_images') &&
              entry.parameters.last == 'image://one',
        ),
        isTrue,
      );
      expect(
        database.executions.any(
          (entry) =>
              entry.sql.contains('INSERT INTO tool_calls') &&
              entry.parameters[3] == 'search',
        ),
        isTrue,
      );
      expect(
        database.executions.any(
          (entry) =>
              entry.sql.contains('INSERT INTO tool_results') &&
              entry.parameters[4] == 'result text',
        ),
        isTrue,
      );
    },
  );

  test(
    'open and list use deterministic ordering and hydrate stored parts',
    () async {
      final instant = DateTime.utc(2026, 8, 29, 12).microsecondsSinceEpoch;
      final database = RecordingDatabase(
        onQuery: (sql, parameters) async {
          if (sql.contains('WHERE server_profile_id = ? AND id = ?')) {
            return <Map<String, Object?>>[
              <String, Object?>{
                'id': 'conversation-1',
                'server_profile_id': 'profile-1',
                'title': 'First user title',
                'selected_model': 'qwen3:4b',
                'system_prompt': 'Use tools only when needed.',
                'created_at': instant,
                'updated_at': instant,
              },
            ];
          }
          if (sql.contains('FROM messages')) {
            return <Map<String, Object?>>[
              <String, Object?>{
                'id': 'assistant-1',
                'conversation_id': 'conversation-1',
                'position': 0,
                'role': 'assistant',
                'status': 'partial',
                'content': 'Persisted partial answer',
                'reasoning': 'Persisted reasoning',
                'provider_transcript_json': null,
                'created_at': instant,
                'updated_at': instant,
              },
            ];
          }
          if (sql.contains('FROM message_images')) {
            return <Map<String, Object?>>[
              <String, Object?>{
                'message_id': 'assistant-1',
                'reference': 'image://one',
              },
            ];
          }
          if (sql.contains('FROM tool_calls')) {
            return <Map<String, Object?>>[
              <String, Object?>{
                'id': 'call-1',
                'message_id': 'assistant-1',
                'name': 'search',
                'arguments_json': '{malformed-json',
              },
            ];
          }
          if (sql.contains('FROM tool_results')) {
            return <Map<String, Object?>>[
              <String, Object?>{
                'id': 'result-1',
                'message_id': 'assistant-1',
                'tool_call_id': 'call-1',
                'content': 'tool output',
                'is_error': 0,
              },
            ];
          }
          if (sql.contains('FROM conversations')) {
            return const <Map<String, Object?>>[];
          }
          throw StateError('Unexpected query: $sql');
        },
      );
      final store = ConversationStore(database);

      final thread = await store.openConversation(
        serverProfileId: 'profile-1',
        id: 'conversation-1',
      );
      await store.listConversations('profile-1');

      expect(thread, isNotNull);
      expect(thread!.conversation.serverProfileId, 'profile-1');
      expect(thread.conversation.selectedModel, 'qwen3:4b');
      expect(thread.conversation.systemPrompt, 'Use tools only when needed.');
      expect(thread.messages.single.status, MessageStatus.partial);
      expect(thread.messages.single.reasoning, 'Persisted reasoning');
      expect(thread.messages.single.imageReferences, <String>['image://one']);
      expect(thread.messages.single.toolCalls.single.name, 'search');
      expect(thread.messages.single.toolCalls.single.arguments, isEmpty);
      expect(thread.messages.single.toolResults.single.content, 'tool output');
    },
  );

  test('first-user title is local, compact, and bounded', () {
    expect(
      titleFromFirstUserText('  hello\n  local   model '),
      'hello local model',
    );
    expect(titleFromFirstUserText('   '), 'New chat');
    expect(titleFromFirstUserText('abcdefghij', maximumLength: 6), 'abcde…');
    expect(titleFromFirstUserText('abc😀def', maximumLength: 5), 'abc😀…');
  });

  test(
    'documents persist through edits and tail replacement with real SQLite',
    () async {
      final fixture = await SqliteStoreFixture.open();
      addTearDown(fixture.close);
      final store = fixture.store;
      final now = DateTime.utc(2026, 9, 10, 12);
      await store.createConversation(
        id: 'conversation-documents',
        serverProfileId: 'profile-1',
        selectedModel: 'model',
        systemPrompt: '',
        now: now,
      );
      final original = await store.appendMessage(
        id: 'message-documents',
        conversationId: 'conversation-documents',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Read this.',
        documents: const <DocumentAttachment>[
          DocumentAttachment(
            id: 'document-1',
            name: 'notes.md',
            mimeType: 'text/markdown',
            reference: '/stored/conversation-documents/notes.md',
            text: '# Notes\nStored context',
          ),
        ],
        now: now,
      );

      await store.replaceConversationTail(
        conversationId: 'conversation-documents',
        fromPosition: 0,
        replacement: original.copyWith(
          content: 'Read this carefully.',
          updatedAt: now.add(const Duration(seconds: 1)),
        ),
      );
      var thread = await store.openConversation(
        serverProfileId: 'profile-1',
        id: 'conversation-documents',
      );
      expect(thread!.messages.single.content, 'Read this carefully.');
      expect(
        {...thread.messages.single.documents.single.toJson()}..remove('id'),
        <String, Object?>{
          'name': 'notes.md',
          'mimeType': 'text/markdown',
          'reference': '/stored/conversation-documents/notes.md',
          'text': '# Notes\nStored context',
        },
      );
      expect(
        await store.isAttachmentReferenceInUse(
          '/stored/conversation-documents/notes.md',
        ),
        isTrue,
      );
      expect(
        await store.isImageReferenceInUse(
          '/stored/conversation-documents/notes.md',
        ),
        isTrue,
      );
      await store.replaceConversationTail(
        conversationId: 'conversation-documents',
        fromPosition: 0,
        replacement: Message(
          id: 'replacement-documents',
          conversationId: 'conversation-documents',
          position: 0,
          role: MessageRole.user,
          status: MessageStatus.complete,
          content: 'Read the replacement.',
          documents: const <DocumentAttachment>[
            DocumentAttachment(
              id: 'document-2',
              name: 'replacement.txt',
              mimeType: 'text/plain',
              reference: '/stored/conversation-documents/replacement.txt',
              text: 'Replacement context',
            ),
          ],
          createdAt: now.add(const Duration(seconds: 2)),
          updatedAt: now.add(const Duration(seconds: 2)),
        ),
      );
      thread = await store.openConversation(
        serverProfileId: 'profile-1',
        id: 'conversation-documents',
      );
      expect(
        thread!.messages.single.documents.single.text,
        'Replacement context',
      );
      expect(
        await store.isAttachmentReferenceInUse(
          '/stored/conversation-documents/notes.md',
        ),
        isTrue,
      );
      expect(
        await store.isAttachmentReferenceInUse(
          '/stored/conversation-documents/replacement.txt',
        ),
        isTrue,
      );
    },
  );

  test(
    'sync deletion is scoped, idempotent, and atomic with its receipt',
    () async {
      final fixture = await SqliteStoreFixture.open();
      addTearDown(fixture.close);
      for (final id in const <String>['delete-me', 'keep-me', 'rollback-me']) {
        await fixture.store.createConversation(
          id: id,
          serverProfileId: 'profile-1',
          selectedModel: 'model',
          systemPrompt: '',
        );
      }
      await fixture.store.saveDrafts(<String, Map<String, Object?>>{
        'delete-me': <String, Object?>{'text': 'delete this draft'},
        'keep-me': <String, Object?>{'text': 'keep this draft'},
        'rollback-me': <String, Object?>{'text': 'rollback this draft'},
        'already-absent': <String, Object?>{'text': 'remove stale draft'},
      });

      await fixture.store.applySyncDeletion(
        conversationId: 'delete-me',
        receiptToken: 'delete-receipt',
      );
      await fixture.store.applySyncDeletion(
        conversationId: 'delete-me',
        receiptToken: 'delete-receipt',
      );
      await fixture.store.applySyncDeletion(
        conversationId: 'already-absent',
        receiptToken: 'absent-receipt',
      );
      expect(await fixture.store.hasSyncReceipt('delete-receipt'), isTrue);
      expect(await fixture.store.hasSyncReceipt('absent-receipt'), isTrue);
      expect((await fixture.store.loadDrafts()).keys, <String>[
        'keep-me',
        'rollback-me',
      ]);
      expect(
        (await fixture.store.listAllConversations(includeEmpty: true))
            .map((conversation) => conversation.id),
        containsAll(<String>['keep-me', 'rollback-me']),
      );

      await fixture.database.execute('''CREATE TRIGGER reject_sync_draft_delete
      BEFORE DELETE ON chat_drafts WHEN OLD.scope = 'rollback-me'
      BEGIN SELECT RAISE(ABORT, 'forced draft failure'); END''');
      await expectLater(
        fixture.store.applySyncDeletion(
          conversationId: 'rollback-me',
          receiptToken: 'rollback-receipt',
        ),
        throwsA(isA<sqflite.DatabaseException>()),
      );
      expect(await fixture.store.hasSyncReceipt('rollback-receipt'), isFalse);
      expect(
        (await fixture.store.loadDrafts())['rollback-me']?['text'],
        'rollback this draft',
      );
      expect(
        (await fixture.store.listAllConversations(includeEmpty: true))
            .map((conversation) => conversation.id),
        contains('rollback-me'),
      );
    },
  );

  test(
    'conversation deletion removes only its matching draft atomically',
    () async {
      final fixture = await SqliteStoreFixture.open();
      addTearDown(fixture.close);
      await fixture.store.createConversation(
        id: 'scoped-delete',
        serverProfileId: 'profile-1',
        selectedModel: 'model',
        systemPrompt: '',
      );
      await fixture.store.saveDrafts(<String, Map<String, Object?>>{
        'scoped-delete': <String, Object?>{'text': 'matching draft'},
        'new:profile-1': <String, Object?>{'text': 'unrelated draft'},
      });

      await fixture.store.deleteConversation(
        serverProfileId: 'wrong-profile',
        id: 'scoped-delete',
      );
      expect(
        await fixture.store.openConversation(
          serverProfileId: 'profile-1',
          id: 'scoped-delete',
        ),
        isNotNull,
      );
      expect(
        (await fixture.store.loadDrafts()).keys,
        contains('scoped-delete'),
      );

      await fixture.database.execute(
        '''CREATE TRIGGER reject_scoped_draft_delete
      BEFORE DELETE ON chat_drafts WHEN OLD.scope = 'scoped-delete'
      BEGIN SELECT RAISE(ABORT, 'forced draft failure'); END''',
      );
      await expectLater(
        fixture.store.deleteConversation(
          serverProfileId: 'profile-1',
          id: 'scoped-delete',
        ),
        throwsA(isA<sqflite.DatabaseException>()),
      );
      expect(
        await fixture.store.openConversation(
          serverProfileId: 'profile-1',
          id: 'scoped-delete',
        ),
        isNotNull,
      );
      expect(
        (await fixture.store.loadDrafts()).keys,
        contains('scoped-delete'),
      );

      await fixture.database.execute('DROP TRIGGER reject_scoped_draft_delete');
      await fixture.store.deleteConversation(
        serverProfileId: 'profile-1',
        id: 'scoped-delete',
      );
      expect(
        await fixture.store.openConversation(
          serverProfileId: 'profile-1',
          id: 'scoped-delete',
        ),
        isNull,
      );
      expect(await fixture.store.loadDrafts(), <String, Map<String, Object?>>{
        'new:profile-1': <String, Object?>{'text': 'unrelated draft'},
      });
    },
  );

  test('delete all conversations and drafts rolls back as one unit', () async {
    final fixture = await SqliteStoreFixture.open();
    addTearDown(fixture.close);
    for (final id in const <String>['first', 'second']) {
      await fixture.store.createConversation(
        id: id,
        serverProfileId: 'profile-1',
        selectedModel: 'model',
        systemPrompt: '',
      );
    }
    await fixture.store.saveDrafts(<String, Map<String, Object?>>{
      'first': <String, Object?>{'text': 'chat draft'},
      'new:profile-1': <String, Object?>{'text': 'new chat draft'},
    });
    await fixture.database.execute('''CREATE TRIGGER reject_all_draft_delete
      BEFORE DELETE ON chat_drafts WHEN OLD.scope = 'new:profile-1'
      BEGIN SELECT RAISE(ABORT, 'forced draft failure'); END''');

    await expectLater(
      fixture.store.deleteAllConversations(),
      throwsA(isA<sqflite.DatabaseException>()),
    );
    expect(
      await fixture.store.listAllConversations(includeEmpty: true),
      hasLength(2),
    );
    expect(await fixture.store.loadDrafts(), hasLength(2));

    await fixture.database.execute('DROP TRIGGER reject_all_draft_delete');
    await fixture.store.deleteAllConversations();
    expect(
      await fixture.store.listAllConversations(includeEmpty: true),
      isEmpty,
    );
    expect(await fixture.store.loadDrafts(), isEmpty);
  });

  test(
    'tail replacement edits and regenerates only the selected tail',
    () async {
      final fixture = await SqliteStoreFixture.open();
      addTearDown(fixture.close);
      final store = fixture.store;
      final start = DateTime.utc(2026, 9, 10, 12);
      await store.createConversation(
        id: 'conversation-1',
        serverProfileId: 'profile-1',
        selectedModel: 'qwen3:4b',
        systemPrompt: 'Be precise.',
        now: start,
      );
      await store.appendMessage(
        id: 'user-1',
        conversationId: 'conversation-1',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Original title prompt',
        now: start.add(const Duration(seconds: 1)),
      );
      await store.appendMessage(
        id: 'assistant-1',
        conversationId: 'conversation-1',
        role: MessageRole.assistant,
        status: MessageStatus.complete,
        content: 'First answer',
        now: start.add(const Duration(seconds: 2)),
      );
      await store.appendMessage(
        id: 'user-2',
        conversationId: 'conversation-1',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Old follow-up',
        now: start.add(const Duration(seconds: 3)),
      );
      await store.appendMessage(
        id: 'assistant-2',
        conversationId: 'conversation-1',
        role: MessageRole.assistant,
        status: MessageStatus.complete,
        content: 'Discarded answer',
        toolCalls: const <ToolCall>[
          ToolCall(
            id: 'discarded-call',
            name: 'search',
            arguments: <String, Object?>{'query': 'old'},
          ),
        ],
        toolResults: const <ToolResult>[
          ToolResult(
            id: 'discarded-result',
            toolCallId: 'discarded-call',
            content: 'old result',
          ),
        ],
        now: start.add(const Duration(seconds: 4)),
      );
      await store.appendMessage(
        id: 'user-3',
        conversationId: 'conversation-1',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Later prompt',
        now: start.add(const Duration(seconds: 5)),
      );

      await store.replaceConversationTail(
        conversationId: 'conversation-1',
        fromPosition: 2,
        replacement: Message(
          id: 'edited-user-2',
          conversationId: 'conversation-1',
          position: 2,
          role: MessageRole.user,
          status: MessageStatus.complete,
          content: 'Edited follow-up',
          createdAt: start.add(const Duration(seconds: 6)),
          updatedAt: start.add(const Duration(seconds: 6)),
        ),
      );

      var thread = await store.openConversation(
        serverProfileId: 'profile-1',
        id: 'conversation-1',
      );
      expect(thread!.messages.map((message) => message.id), <String>[
        'user-1',
        'assistant-1',
        'edited-user-2',
      ]);
      expect(thread.messages.last.content, 'Edited follow-up');
      expect(thread.conversation.title, 'Original title prompt');
      final versions = (await store.openConversation(
        serverProfileId: 'profile-1',
        id: 'conversation-1',
        allBranches: true,
      ))!;
      final retained = versions.allNodes.singleWhere(
        (m) => m.id == 'assistant-2',
      );
      expect(retained.toolCalls.single.id, 'discarded-call');
      expect(retained.toolResults.single.content, 'old result');

      await store.replaceConversationTail(
        conversationId: 'conversation-1',
        fromPosition: 1,
      );
      thread = await store.openConversation(
        serverProfileId: 'profile-1',
        id: 'conversation-1',
      );
      expect(thread!.messages.map((message) => message.id), <String>['user-1']);
      expect(thread.conversation.title, 'Original title prompt');
    },
  );

  test('tail replacement preserves an explicitly renamed title', () async {
    final fixture = await SqliteStoreFixture.open();
    addTearDown(fixture.close);
    final store = fixture.store;
    final now = DateTime.utc(2026, 9, 10, 12);
    await store.createConversation(
      id: 'conversation-1',
      serverProfileId: 'profile-1',
      selectedModel: 'model',
      systemPrompt: '',
      now: now,
    );
    await store.appendMessage(
      id: 'user-1',
      conversationId: 'conversation-1',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Original prompt',
      now: now,
    );
    await store.rename('conversation-1', 'Kept custom title');

    await store.replaceConversationTail(
      conversationId: 'conversation-1',
      fromPosition: 0,
      replacement: Message(
        id: 'edited-user',
        conversationId: 'conversation-1',
        position: 0,
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'A completely different prompt',
        createdAt: now,
        updatedAt: now,
      ),
    );

    final thread = await store.openConversation(
      serverProfileId: 'profile-1',
      id: 'conversation-1',
    );
    expect(thread!.conversation.title, 'Kept custom title');
    expect(thread.conversation.isRenamed, isTrue);
  });

  test('tail replacement rolls back when insertion fails', () async {
    final fixture = await SqliteStoreFixture.open();
    addTearDown(fixture.close);
    final store = fixture.store;
    final now = DateTime.utc(2026, 9, 10, 12);
    await store.createConversation(
      id: 'conversation-1',
      serverProfileId: 'profile-1',
      selectedModel: 'model',
      systemPrompt: '',
      now: now,
    );
    await store.appendMessage(
      id: 'user-1',
      conversationId: 'conversation-1',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Keep me',
      now: now,
    );
    await store.appendMessage(
      id: 'assistant-1',
      conversationId: 'conversation-1',
      role: MessageRole.assistant,
      status: MessageStatus.complete,
      content: 'Keep me too after rollback',
      now: now,
    );
    await fixture.database.execute('''CREATE TRIGGER reject_replacement
      BEFORE INSERT ON messages WHEN NEW.id = 'replacement'
      BEGIN SELECT RAISE(ABORT, 'forced failure'); END''');

    await expectLater(
      store.replaceConversationTail(
        conversationId: 'conversation-1',
        fromPosition: 1,
        replacement: Message(
          id: 'replacement',
          conversationId: 'conversation-1',
          position: 1,
          role: MessageRole.assistant,
          status: MessageStatus.complete,
          content: 'Fails to insert',
          createdAt: now,
          updatedAt: now,
        ),
      ),
      throwsA(isA<sqflite.DatabaseException>()),
    );

    final thread = await store.openConversation(
      serverProfileId: 'profile-1',
      id: 'conversation-1',
    );
    expect(thread!.messages.map((message) => message.id), <String>[
      'user-1',
      'assistant-1',
    ]);
  });

  test('draft replacement is durable and rolls back as one unit', () async {
    final fixture = await SqliteStoreFixture.open();
    addTearDown(fixture.close);
    await fixture.store.saveDrafts(<String, Map<String, Object?>>{
      'new:profile-1': <String, Object?>{
        'text': 'first draft',
        'image': '/stored/image.jpg',
      },
      'conversation-1': <String, Object?>{'text': 'follow-up'},
    });
    expect(await fixture.store.loadDrafts(), <String, Map<String, Object?>>{
      'conversation-1': <String, Object?>{'text': 'follow-up'},
      'new:profile-1': <String, Object?>{
        'text': 'first draft',
        'image': '/stored/image.jpg',
      },
    });

    await fixture.database.execute('''CREATE TRIGGER reject_draft
      BEFORE INSERT ON chat_drafts WHEN NEW.scope = 'blocked'
      BEGIN SELECT RAISE(ABORT, 'forced failure'); END''');
    await expectLater(
      fixture.store.saveDrafts(<String, Map<String, Object?>>{
        'replacement': <String, Object?>{'text': 'new'},
        'blocked': <String, Object?>{'text': 'fail'},
      }),
      throwsA(isA<sqflite.DatabaseException>()),
    );
    expect((await fixture.store.loadDrafts()).keys, <String>[
      'conversation-1',
      'new:profile-1',
    ]);
  });
}

final class SqliteStoreFixture {
  const SqliteStoreFixture(this.database, this.store);

  final sqflite.Database database;
  final ConversationStore store;

  static Future<SqliteStoreFixture> open() async {
    final database = await sqflite.databaseFactoryFfiNoIsolate.openDatabase(
      sqflite.inMemoryDatabasePath,
      options: sqflite.OpenDatabaseOptions(singleInstance: false),
    );
    final store = ConversationStore(SqfliteDatabaseAdapter(database));
    await store.migrate(fromVersion: 0, legacyServerProfileId: 'profile-1');
    return SqliteStoreFixture(database, store);
  }

  Future<void> close() => database.close();
}

typedef QueryHandler = Future<List<Map<String, Object?>>> Function(
  String sql,
  List<Object?> parameters,
);

class SqlInvocation {
  const SqlInvocation(this.sql, this.parameters);

  final String sql;
  final List<Object?> parameters;
}

class RecordingDatabase implements SqliteDatabase {
  RecordingDatabase({this.onQuery});

  final QueryHandler? onQuery;
  final List<SqlInvocation> executions = <SqlInvocation>[];
  final List<SqlInvocation> queries = <SqlInvocation>[];
  int transactionCount = 0;

  @override
  Future<void> execute(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    executions.add(SqlInvocation(_compact(sql), List<Object?>.of(parameters)));
  }

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> parameters = const [],
  ]) async {
    final compactSql = _compact(sql);
    final copiedParameters = List<Object?>.of(parameters);
    queries.add(SqlInvocation(compactSql, copiedParameters));
    return onQuery?.call(compactSql, copiedParameters) ??
        const <Map<String, Object?>>[];
  }

  @override
  Future<T> transaction<T>(
    Future<T> Function(SqliteDatabase database) action,
  ) async {
    transactionCount++;
    return action(this);
  }

  static String _compact(String sql) =>
      sql.trim().replaceAll(RegExp(r'\s+'), ' ');
}
