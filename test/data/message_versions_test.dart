import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/data/chat_backup.dart';
import 'package:mobollama/domain/chat_folder.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/message_graph.dart';

import '../support/chat_fixture.dart';

void main() {
  test('old edited checkpoint becomes a retained branch and each continuation stays separate after reopening', () async {
    final f = ChatFixture();
    await f.open(version: 12);
    addTearDown(f.close);
    await f.store.createConversation(
      id: 'chat',
      serverProfileId: 'home',
      selectedModel: 'model',
      systemPrompt: '',
    );
    final user = await f.store.appendMessage(
      id: 'question',
      conversationId: 'chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Original question',
      imageReferences: ['owned-image'],
    );
    await f.store.appendMessage(
      id: 'original-answer',
      conversationId: 'chat',
      role: MessageRole.assistant,
      status: MessageStatus.complete,
      content: 'Original answer',
    );
    await f.store.replaceConversationTail(
      conversationId: 'chat',
      fromPosition: 0,
      replacement: user.copyWith(content: 'Edited question'),
      saveRecoveryCheckpoint: true,
    );
    await f.store.appendMessage(
      id: 'edited-answer',
      conversationId: 'chat',
      role: MessageRole.assistant,
      status: MessageStatus.complete,
      content: 'Edited answer',
    );
    await f.store.migrate(
      fromVersion: 12,
      toVersion: 13,
      legacyServerProfileId: 'home',
    );
    var thread = (await f.store.openConversation(
      serverProfileId: 'home',
      id: 'chat',
      allBranches: true,
    ))!;
    expect(thread.messages.map((m) => m.content), [
      'Edited question',
      'Edited answer',
    ]);
    expect(thread.allNodes, hasLength(4));
    final graph = MessageGraph(thread.allNodes);
    final oldUser = thread.allNodes.singleWhere(
      (m) => m.content == 'Original question',
    );
    expect(oldUser.id, isNot('question'));
    expect(oldUser.imageReferences, ['owned-image']);
    expect(graph.branch('original-answer').map((m) => m.content), [
      'Original question',
      'Original answer',
    ]);
    expect(await f.store.recoveryCheckpointConversationIds(), contains('chat'));
    await f.store.selectTip('chat', 'original-answer');
    await f.store.appendMessage(
      id: 'old-followup',
      conversationId: 'chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Follow original',
    );
    await f.store.selectTip('chat', 'edited-answer');
    await f.store.appendMessage(
      id: 'new-followup',
      conversationId: 'chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Follow edit',
    );
    final reopened = ConversationStore(SqfliteDatabaseAdapter(f.database));
    await reopened.migrate(
      fromVersion: 13,
      toVersion: 13,
      legacyServerProfileId: 'home',
    );
    thread = (await reopened.openConversation(
      serverProfileId: 'home',
      id: 'chat',
      allBranches: true,
    ))!;
    expect(thread.messages.map((m) => m.content), [
      'Edited question',
      'Edited answer',
      'Follow edit',
    ]);
    expect(
      MessageGraph(thread.allNodes)
          .branch('old-followup')
          .map((m) => m.content),
      ['Original question', 'Original answer', 'Follow original'],
    );
    final newest = (await reopened.openWindow(
      serverProfileId: 'home',
      id: 'chat',
      limit: 2,
    ))!;
    final older = (await reopened.openWindow(
      serverProfileId: 'home',
      id: 'chat',
      before: newest.previousCursor,
      limit: 2,
    ))!;
    expect(
      [
        ...older.thread.messages,
        ...newest.thread.messages,
      ].map((m) => m.content),
      thread.messages.map((m) => m.content),
    );
    expect(await reopened.isAttachmentReferenceInUse('owned-image'), isTrue);
    await reopened.saveFolder(
      const ChatFolder(
        id: 'empty-folder',
        name: 'Research',
        instructions: 'Use references.',
        revision: 1,
      ),
    );
    await reopened.moveToFolder('chat', 'empty-folder');
    final backup = await ChatBackup(reopened).exportJson(
      serverProfiles: [
        const BackupServerProfile(
          id: 'home',
          name: 'Home',
          protocol: 'ollama',
          baseUrl: 'https://home.test',
        ),
      ],
      readAttachment: (_) async => [1, 2, 3],
    );
    final copy = ChatFixture();
    await copy.open(version: 12);
    addTearDown(copy.close);
    await copy.store.migrate(
      fromVersion: 12,
      toVersion: 13,
      legacyServerProfileId: 'home',
    );
    var sequence = 0;
    await ChatBackup(copy.store).importJson(
      json: backup,
      serverProfileMappings: {'home': 'lab'},
      allocateId: () => 'copy-${sequence++}',
      writeAttachment: (attachment, chat) async => 'copy-image-${sequence++}',
      deleteAttachment: (_) async {},
    );
    final imported = (await copy.store.listAllConversations()).single;
    final restored = (await copy.store.openConversation(
      serverProfileId: 'lab',
      id: imported.id,
      allBranches: true,
    ))!;
    expect(restored.allNodes, hasLength(6));
    expect(restored.messages.map((m) => m.content), [
      'Edited question',
      'Edited answer',
      'Follow edit',
    ]);
    final restoredOld = restored.allNodes.singleWhere(
      (m) => m.content == 'Follow original',
    );
    expect(
      MessageGraph(restored.allNodes)
          .branch(restoredOld.id)
          .map((m) => m.content),
      ['Original question', 'Original answer', 'Follow original'],
    );
    expect((await copy.store.folders()).single.name, 'Research');
    expect(imported.folderId, (await copy.store.folders()).single.id);
    expect(await f.database.rawQuery('PRAGMA foreign_key_check'), isEmpty);
  });
}
