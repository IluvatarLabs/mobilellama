import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/attachment_reference_codec.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/document_attachment.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/queued_prompt.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite;

void main() {
  setUpAll(sqflite.sqfliteFfiInit);

  test(
    'queue survives reopening and enforces scoped exact-set ordering',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'mobilellama-queue-persistence-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final databasePath = path.join(temporary.path, 'chat.sqlite');
      var fixture = await _QueueFixture.open(databasePath: databasePath);
      for (final id in const <String>['first-chat', 'second-chat']) {
        await fixture.store.createConversation(
          id: id,
          serverProfileId: 'profile',
          selectedModel: 'model',
          systemPrompt: '',
        );
      }
      final start = DateTime.utc(2026, 9, 11, 12);
      for (var index = 1; index <= 3; index++) {
        await fixture.store.enqueuePrompt(
          _prompt(
            id: 'queue-$index',
            conversationId: 'first-chat',
            text: 'Prompt $index',
            createdAt: start.add(Duration(seconds: index)),
          ),
        );
      }
      await fixture.store.enqueuePrompt(
        _prompt(
          id: 'other-queue',
          conversationId: 'second-chat',
          text: '',
          imageReferences: const <String>['/attachments/only.png'],
          createdAt: start,
        ),
      );
      await expectLater(
        fixture.store.enqueuePrompt(
          _prompt(id: 'empty', conversationId: 'second-chat', text: '   '),
        ),
        throwsFormatException,
      );

      expect(
        (await fixture.store.listAllConversations()).map(
          (conversation) => conversation.id,
        ),
        containsAll(<String>['first-chat', 'second-chat']),
      );
      await fixture.store.updateQueuedPromptText(
        conversationId: 'first-chat',
        id: 'queue-2',
        text: 'Edited prompt',
      );
      await expectLater(
        fixture.store.updateQueuedPromptText(
          conversationId: 'second-chat',
          id: 'queue-1',
          text: 'Wrong chat',
        ),
        throwsFormatException,
      );
      await expectLater(
        fixture.store.deleteQueuedPrompt(
          conversationId: 'second-chat',
          id: 'queue-1',
        ),
        throwsFormatException,
      );
      await fixture.store.reorderQueuedPrompts(
        conversationId: 'first-chat',
        ids: const <String>['queue-3', 'queue-2', 'queue-1'],
      );
      await expectLater(
        fixture.store.reorderQueuedPrompts(
          conversationId: 'first-chat',
          ids: const <String>['queue-3', 'queue-1'],
        ),
        throwsFormatException,
      );
      expect(
        (await fixture.store.loadQueuedPrompts(conversationId: 'first-chat'))
            .map((prompt) => (prompt.id, prompt.text)),
        <(String, String)>[
          ('queue-3', 'Prompt 3'),
          ('queue-2', 'Edited prompt'),
          ('queue-1', 'Prompt 1'),
        ],
      );
      await fixture.store.deleteQueuedPrompt(
        conversationId: 'first-chat',
        id: 'queue-2',
      );
      await expectLater(
        fixture.store.enqueuePrompt(
          _prompt(
            id: 'queue-1',
            conversationId: 'first-chat',
            text: 'Duplicate',
            createdAt: start,
          ),
        ),
        throwsFormatException,
      );
      await fixture.close();

      fixture = await _QueueFixture.open(
        databasePath: databasePath,
        fromVersion: ConversationStore.schemaVersion,
      );
      addTearDown(fixture.close);
      expect(
        (await fixture.store.loadQueuedPrompts(conversationId: 'first-chat'))
            .map((prompt) => prompt.id),
        <String>['queue-3', 'queue-1'],
      );
      expect(
        (await fixture.store.loadQueuedPrompts()).map((prompt) => prompt.id),
        <String>['queue-3', 'queue-1', 'other-queue'],
      );
    },
  );

  test('claim and restore preserve FIFO content and attachments', () async {
    final fixture = await _QueueFixture.open();
    addTearDown(fixture.close);
    final store = fixture.store;
    final start = DateTime.utc(2026, 9, 11, 12);
    await store.createConversation(
      id: 'chat',
      serverProfileId: 'profile',
      selectedModel: 'model',
      systemPrompt: '',
      now: start,
    );
    await store.appendMessage(
      id: 'existing-user',
      conversationId: 'chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Existing title',
      now: start,
    );
    await store.appendMessage(
      id: 'existing-assistant',
      conversationId: 'chat',
      role: MessageRole.assistant,
      status: MessageStatus.complete,
      content: 'Existing answer',
      now: start,
    );
    final document = DocumentAttachment(
      id: 'document',
      name: 'notes.md',
      mimeType: 'text/markdown',
      reference: '/attachments/notes.md',
      text: '# Notes',
    );
    await store.enqueuePrompt(
      _prompt(
        id: 'first',
        conversationId: 'chat',
        text: 'Queued with files',
        imageReferences: const <String>['/attachments/image.png'],
        documents: <DocumentAttachment>[document],
        createdAt: start.add(const Duration(seconds: 1)),
      ),
    );
    await store.enqueuePrompt(
      _prompt(
        id: 'second',
        conversationId: 'chat',
        text: 'Next prompt',
        createdAt: start.add(const Duration(seconds: 2)),
      ),
    );

    final claim = await store.claimQueuedPrompt(
      'chat',
      userMessageId: 'claimed-user',
      assistantMessageId: 'claimed-assistant',
      now: start.add(const Duration(seconds: 3)),
    );
    expect(claim, isNotNull);
    expect(claim!.prompt.id, 'first');
    expect(
      (await store.loadQueuedPrompts(conversationId: 'chat'))
          .map((prompt) => prompt.id),
      <String>['second'],
    );
    var thread = await store.openConversation(
      serverProfileId: 'profile',
      id: 'chat',
    );
    expect(thread!.messages.map((message) => message.id), <String>[
      'existing-user',
      'existing-assistant',
      'claimed-user',
      'claimed-assistant',
    ]);
    expect(thread.messages[2].imageReferences, <String>[
      '/attachments/image.png',
    ]);
    expect(thread.messages[2].documents.single.toJson(), document.toJson());
    expect(thread.messages.last.status, MessageStatus.streaming);
    expect(thread.conversation.title, 'Existing title');
    await expectLater(
      store.claimQueuedPrompt(
        'chat',
        userMessageId: 'another-user',
        assistantMessageId: 'another-assistant',
      ),
      throwsFormatException,
    );

    await store.updateMessage(
      thread.messages.last.copyWith(
        status: MessageStatus.failed,
        updatedAt: start.add(const Duration(seconds: 4)),
      ),
    );
    await fixture.database.execute('''CREATE TRIGGER reject_queue_restore
      BEFORE INSERT ON queued_prompts WHEN NEW.id = 'first'
      BEGIN SELECT RAISE(ABORT, 'forced queue restore failure'); END''');
    await expectLater(
      store.restoreQueuedPrompt(claim),
      throwsA(isA<sqflite.DatabaseException>()),
    );
    thread = await store.openConversation(
      serverProfileId: 'profile',
      id: 'chat',
    );
    expect(thread!.messages.map((message) => message.id), <String>[
      'existing-user',
      'existing-assistant',
      'claimed-user',
      'claimed-assistant',
    ]);
    expect(
      (await store.loadQueuedPrompts(conversationId: 'chat'))
          .map((prompt) => prompt.id),
      <String>['second'],
    );
    await fixture.database.execute('DROP TRIGGER reject_queue_restore');
    await store.restoreQueuedPrompt(claim);
    thread = await store.openConversation(
      serverProfileId: 'profile',
      id: 'chat',
    );
    expect(thread!.messages.map((message) => message.id), <String>[
      'existing-user',
      'existing-assistant',
    ]);
    expect(
      (await store.loadQueuedPrompts(conversationId: 'chat'))
          .map((prompt) => prompt.id),
      <String>['first', 'second'],
    );
    expect(
      await store.isAttachmentReferenceInUse('/attachments/image.png'),
      isTrue,
    );
    expect(
      await store.isAttachmentReferenceInUse('/attachments/notes.md'),
      isTrue,
    );
    await expectLater(store.restoreQueuedPrompt(claim), throwsFormatException);
    expect(
      (await store.loadQueuedPrompts(conversationId: 'chat'))
          .where((prompt) => prompt.id == 'first'),
      hasLength(1),
    );
  });

  test(
    'claim rolls back on insertion failure and cascade removes queue',
    () async {
      final fixture = await _QueueFixture.open();
      addTearDown(fixture.close);
      await fixture.store.createConversation(
        id: 'chat',
        serverProfileId: 'profile',
        selectedModel: 'model',
        systemPrompt: '',
      );
      await fixture.store.enqueuePrompt(
        _prompt(
          id: 'queued',
          conversationId: 'chat',
          text: 'Do not lose me',
          imageReferences: const <String>['/attachments/queued.png'],
        ),
      );
      expect((await fixture.store.listAllConversations()).single.id, 'chat');
      await fixture.database.execute('''CREATE TRIGGER reject_claim_assistant
      BEFORE INSERT ON messages WHEN NEW.id = 'assistant-failure'
      BEGIN SELECT RAISE(ABORT, 'forced assistant insert failure'); END''');

      await expectLater(
        fixture.store.claimQueuedPrompt(
          'chat',
          userMessageId: 'user-failure',
          assistantMessageId: 'assistant-failure',
        ),
        throwsA(isA<sqflite.DatabaseException>()),
      );
      expect(
        (await fixture.store.loadQueuedPrompts(conversationId: 'chat'))
            .single
            .id,
        'queued',
      );
      expect(
        await fixture.database.rawQuery(
          'SELECT id FROM messages WHERE conversation_id = ?',
          <Object?>['chat'],
        ),
        isEmpty,
      );
      expect(
        await fixture.store.isAttachmentReferenceInUse(
          '/attachments/queued.png',
        ),
        isTrue,
      );

      await fixture.store.deleteConversation(
        serverProfileId: 'profile',
        id: 'chat',
      );
      expect(await fixture.store.loadQueuedPrompts(), isEmpty);
      expect(
        await fixture.store.isAttachmentReferenceInUse(
          '/attachments/queued.png',
        ),
        isFalse,
      );
    },
  );

  test('restore refuses to delete work appended after the claim', () async {
    final fixture = await _QueueFixture.open();
    addTearDown(fixture.close);
    await fixture.store.createConversation(
      id: 'chat',
      serverProfileId: 'profile',
      selectedModel: 'model',
      systemPrompt: '',
    );
    await fixture.store.enqueuePrompt(
      _prompt(id: 'queued', conversationId: 'chat', text: 'Queued prompt'),
    );
    final claim = (await fixture.store.claimQueuedPrompt(
      'chat',
      userMessageId: 'claimed-user',
      assistantMessageId: 'claimed-assistant',
    ))!;
    await fixture.store.appendMessage(
      id: 'later-user',
      conversationId: 'chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Later work',
    );

    await expectLater(
      fixture.store.restoreQueuedPrompt(claim),
      throwsFormatException,
    );
    final thread = await fixture.store.openConversation(
      serverProfileId: 'profile',
      id: 'chat',
    );
    expect(thread!.messages.map((message) => message.id), <String>[
      'claimed-user',
      'claimed-assistant',
      'later-user',
    ]);
    expect(await fixture.store.loadQueuedPrompts(), isEmpty);
  });

  test(
    'queued and draft attachments follow a relocated app container',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'mobilellama-queue-relocation-',
      );
      addTearDown(() async {
        if (await temporary.exists()) await temporary.delete(recursive: true);
      });
      final oldRoot = Directory(
        path.join(temporary.path, 'old', 'Documents', 'chat-images'),
      );
      final files = Directory(path.join(oldRoot.path, 'chat'));
      await files.create(recursive: true);
      final image = await File(path.join(files.path, 'image.png'))
          .writeAsBytes(<int>[1, 2, 3]);
      final documentFile = await File(path.join(files.path, 'notes.txt'))
          .writeAsString('document bytes');
      final document = DocumentAttachment(
        id: 'document',
        name: 'notes.txt',
        mimeType: 'text/plain',
        reference: documentFile.path,
        text: 'document bytes',
      );
      final databasePath = path.join(temporary.path, 'chat.sqlite');
      var fixture = await _QueueFixture.open(
        databasePath: databasePath,
        codec: RootedAttachmentReferenceCodec(oldRoot.path),
      );
      await fixture.store.createConversation(
        id: 'chat',
        serverProfileId: 'profile',
        selectedModel: 'model',
        systemPrompt: '',
      );
      await fixture.store.enqueuePrompt(
        _prompt(
          id: 'relative',
          conversationId: 'chat',
          text: 'Relative files',
          imageReferences: <String>[image.path],
          documents: <DocumentAttachment>[document],
        ),
      );
      await fixture.store.saveDrafts(<String, Map<String, Object?>>{
        'chat': <String, Object?>{
          'text': 'Draft with multiple images',
          'image': image.path,
          'images': <String>[image.path],
          'documents': <Map<String, Object?>>[document.toJson()],
        },
      });
      final rawQueue = (await fixture.database.rawQuery(
        'SELECT images_json, documents_json FROM queued_prompts WHERE id = ?',
        <Object?>['relative'],
      )).single;
      expect(
        path.isAbsolute(
          (jsonDecode(rawQueue['images_json']! as String) as List).single
              as String,
        ),
        isFalse,
      );
      expect(
        path.isAbsolute(
          ((jsonDecode(rawQueue['documents_json']! as String) as List).single
                  as Map)['reference']
              as String,
        ),
        isFalse,
      );

      await fixture.database.rawInsert(
        '''INSERT INTO queued_prompts(
             id, conversation_id, position, text, images_json,
             documents_json, created_at
           ) VALUES(?, ?, ?, ?, ?, ?, ?)''',
        <Object?>[
          'legacy',
          'chat',
          1,
          'Legacy absolute files',
          jsonEncode(<String>[image.path]),
          jsonEncode(<Map<String, Object?>>[document.toJson()]),
          DateTime.utc(2026, 9, 11).microsecondsSinceEpoch,
        ],
      );
      await fixture.close();

      final newRoot = Directory(
        path.join(temporary.path, 'new', 'Documents', 'chat-images'),
      );
      await newRoot.parent.create(recursive: true);
      await oldRoot.rename(newRoot.path);
      fixture = await _QueueFixture.open(
        databasePath: databasePath,
        codec: RootedAttachmentReferenceCodec(newRoot.path),
        fromVersion: ConversationStore.schemaVersion,
      );
      addTearDown(fixture.close);
      final expectedImage = path.join(newRoot.path, 'chat', 'image.png');
      final expectedDocument = path.join(newRoot.path, 'chat', 'notes.txt');
      final queue = await fixture.store.loadQueuedPrompts(
        conversationId: 'chat',
      );
      expect(queue.map((prompt) => prompt.id), <String>['relative', 'legacy']);
      for (final prompt in queue) {
        expect(prompt.imageReferences.single, expectedImage);
        expect(prompt.documents.single.reference, expectedDocument);
      }
      expect(await File(expectedImage).readAsBytes(), <int>[1, 2, 3]);
      expect(await File(expectedDocument).readAsString(), 'document bytes');
      expect(
        await fixture.store.isAttachmentReferenceInUse(expectedImage),
        isTrue,
      );
      expect(
        await fixture.store.isAttachmentReferenceInUse(expectedDocument),
        isTrue,
      );
      final draft = (await fixture.store.loadDrafts())['chat']!;
      expect(draft['image'], expectedImage);
      expect(draft['images'], <String>[expectedImage]);
      final draftDocument = DocumentAttachment.fromJson(
        Map<String, Object?>.from((draft['documents']! as List).single as Map),
      );
      expect(draftDocument.reference, expectedDocument);

      final outside = await File(path.join(temporary.path, 'outside.png'))
          .writeAsBytes(<int>[9]);
      await expectLater(
        fixture.store.enqueuePrompt(
          _prompt(
            id: 'outside',
            conversationId: 'chat',
            text: 'Foreign file',
            imageReferences: <String>[outside.path],
          ),
        ),
        throwsFormatException,
      );
      expect(
        (await fixture.store.loadQueuedPrompts(conversationId: 'chat'))
            .map((prompt) => prompt.id),
        <String>['relative', 'legacy'],
      );

      final claim = await fixture.store.claimQueuedPrompt(
        'chat',
        userMessageId: 'relocated-user',
        assistantMessageId: 'relocated-assistant',
      );
      final thread = await fixture.store.openConversation(
        serverProfileId: 'profile',
        id: 'chat',
      );
      expect(thread!.messages.first.imageReferences.single, expectedImage);
      expect(
        thread.messages.first.documents.single.reference,
        expectedDocument,
      );
      await fixture.store.restoreQueuedPrompt(claim!);
      expect(
        (await fixture.store.loadQueuedPrompts(conversationId: 'chat'))
            .first
            .id,
        'relative',
      );
    },
  );
}

QueuedPrompt _prompt({
  required String id,
  required String conversationId,
  required String text,
  List<String> imageReferences = const <String>[],
  List<DocumentAttachment> documents = const <DocumentAttachment>[],
  DateTime? createdAt,
}) => QueuedPrompt(
  id: id,
  conversationId: conversationId,
  text: text,
  imageReferences: imageReferences,
  documents: documents,
  createdAt: createdAt ?? DateTime.utc(2026, 9, 11, 12),
);

final class _QueueFixture {
  const _QueueFixture(this.database, this.store);

  final sqflite.Database database;
  final ConversationStore store;

  static Future<_QueueFixture> open({
    String? databasePath,
    AttachmentReferenceCodec codec = const IdentityAttachmentReferenceCodec(),
    int fromVersion = 0,
  }) async {
    final database = await sqflite.databaseFactoryFfiNoIsolate.openDatabase(
      databasePath ?? sqflite.inMemoryDatabasePath,
      options: sqflite.OpenDatabaseOptions(singleInstance: false),
    );
    final store = ConversationStore(
      SqfliteDatabaseAdapter(database),
      referenceCodec: codec,
    );
    await store.migrate(
      fromVersion: fromVersion,
      legacyServerProfileId: 'profile',
    );
    return _QueueFixture(database, store);
  }

  Future<void> close() => database.close();
}
