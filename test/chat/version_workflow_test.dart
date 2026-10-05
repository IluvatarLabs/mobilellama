import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/domain/message_graph.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/queued_prompt.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/domain/generation_options.dart';

import '../support/chat_fixture.dart';

void main() {
  test('an empty composer with saved settings follows regeneration after abrupt relaunch', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.controller.initialize();
    await f.controller.updateSystemPrompt('Keep the answer brief');
    expect(await f.controller.send('First question'), isTrue);
    final chatId = f.controller.conversation!.id;
    final oldAnswer = f.controller.messages.last.id;
    expect(await f.controller.regenerateAssistant(oldAnswer), isTrue);
    await f.controller.viewVersion(oldAnswer);
    await f.controller.continueViewedVersion();
    expect(await f.controller.regenerateAssistant(oldAnswer), isTrue);
    final regenerated = f.controller.messages.last.id;
    // Restore the committed draft snapshot from before orderly fixture cleanup,
    // so shutdown cannot accidentally repair the state a terminated app sees.
    final committedDrafts = await f.store.loadDrafts();
    await f.controller.shutdown();
    f.controller.dispose();
    await f.store.saveDrafts(committedDrafts);
    f.createController();
    await f.controller.initialize();
    await f.controller.openConversation(chatId);
    expect(await f.controller.send('Next question'), isTrue);
    expect(
      f.controller.messages[f.controller.messages.length - 2].parentId,
      regenerated,
    );
    expect(f.requests.last.toString(), contains('Keep the answer brief'));
  });
  test('regenerate a middle answer, view without changing continuation, then continue each retained branch', () async {
    final f = ChatFixture();
    await f.open(version: 13);
    addTearDown(f.close);
    await f.seed('chat', content: 'Original useful answer');
    await f.controller.initialize();
    await f.controller.openConversation('chat');
    expect(await f.controller.send('Original follow-up'), isTrue);
    final oldTip = f.controller.messages.last.id;
    expect(await f.controller.regenerateAssistant('chat-assistant'), isTrue);
    final newAnswer = f.controller.messages.last.id;
    expect(
      f.controller.messages.map((m) => m.content),
      isNot(contains('Original follow-up')),
    );
    await f.controller.viewVersion('chat-assistant');
    expect(f.controller.viewingAlternative, isTrue);
    await f.controller.prepareFindInChat();
    expect(f.controller.viewingAlternative, isTrue);
    expect(
      f.controller.messages.map((m) => m.content),
      contains('Original follow-up'),
    );
    expect(
      (await f.store.openConversation(
        serverProfileId: 'home',
        id: 'chat',
      ))!.conversation.activeTipId,
      newAnswer,
    );
    expect(f.controller.canSend, isFalse);
    await f.controller.continueViewedVersion();
    expect(await f.controller.send('Continue original branch'), isTrue);
    final oldContinuation = f.controller.messages.last.id;
    await f.controller.viewVersion(newAnswer);
    await f.controller.continueViewedVersion();
    expect(await f.controller.send('Continue regenerated branch'), isTrue);
    final request = f.requests.last;
    expect(request.toString(), contains('Continue regenerated branch'));
    expect(request.toString(), isNot(contains('Original follow-up')));
    expect(request.toString(), isNot(contains('Continue original branch')));
    final originalUser = f.controller.messages.first.id;
    expect(
      await f.controller.editAndResend(originalUser, 'Revised first question'),
      isTrue,
    );
    final all = (await f.store.openConversation(
      serverProfileId: 'home',
      id: 'chat',
      allBranches: true,
    ))!;
    final graph = MessageGraph(all.allNodes);
    expect(
      graph.branch(oldTip).map((m) => m.content),
      contains('Original follow-up'),
    );
    expect(
      graph.branch(oldContinuation).map((m) => m.content),
      contains('Continue original branch'),
    );
    expect(all.messages.first.content, 'Revised first question');
    await f.controller.shutdown();
    f.controller.dispose();
    f.createController();
    await f.controller.initialize();
    await f.controller.openConversation('chat');
    expect(f.controller.messages.first.content, 'Revised first question');
    await f.controller.viewVersion(originalUser);
    expect(f.controller.messages.first.content, 'Saved conversation');
    await f.controller.newConversation();
    expect(f.controller.viewingAlternative, isFalse);
    expect(
      (await f.store.openConversation(
        serverProfileId: 'home',
        id: 'chat',
        allBranches: true,
      ))!.allNodes.length,
      all.allNodes.length,
    );
  });
  test('folder moves and defaults preserve saved instructions while an explicit empty override stays empty', () async {
    final f = ChatFixture();
    await f.open(version: 13);
    addTearDown(f.close);
    await f.controller.initialize();
    await f.controller.updateChatDefaults(
      systemPrompt: 'Profile default',
      generationOptions: const GenerationOptions(),
    );
    await f.controller.saveFolder(
      name: 'Research',
      instructions: 'Folder instructions',
    );
    final folder = f.controller.folders.single;
    await f.controller.newConversationInFolder(folder.id);
    await f.controller.send('Start research');
    final chat = f.controller.conversation!;
    expect(chat.instructionSource, 'folderSnapshot');
    expect(
      f.requests.last['messages'].toString(),
      contains('Folder instructions'),
    );
    f.controller.setDraftText('Keep my draft');
    await f.controller.saveFolder(
      id: folder.id,
      name: 'Renamed research',
      instructions: 'Changed folder instructions',
    );
    await f.controller.moveConversationToFolder(chat.id, null);
    expect(f.controller.draftText, 'Keep my draft');
    await f.controller.updateChatDefaults(
      systemPrompt: 'Changed profile default',
      generationOptions: const GenerationOptions(),
    );
    await f.controller.send('Keep my draft');
    expect(
      f.requests.last['messages'].toString(),
      contains('Folder instructions'),
    );
    expect(
      f.requests.last['messages'].toString(),
      isNot(contains('Changed folder instructions')),
    );
    await f.controller.updateSystemPrompt('');
    await f.controller.send('No instructions');
    expect(
      (f.requests.last['messages'] as List).where((m) => m['role'] == 'system'),
      isEmpty,
    );
    expect(f.controller.conversation!.instructionSource, 'explicit');
    await f.controller.moveConversationToFolder(chat.id, folder.id);
    await f.controller.deleteFolder(folder.id);
    expect(f.controller.history.any((c) => c.id == chat.id), isTrue);
    expect(f.controller.conversation!.folderId, isNull);
    expect(f.controller.systemPrompt, '');
  });
  test('an unfinished inactive alternative cannot block a settled branch queue; reopening labels abandoned versions', () async {
    final f = ChatFixture();
    await f.open(version: 13);
    addTearDown(f.close);
    await f.seed('chat', content: 'Keep this answer');
    final stale = await f.store.createAlternative(
      targetId: 'chat-assistant',
      assistantId: 'stale',
    );
    await f.store.selectTip('chat', 'chat-assistant');
    final interrupted = await f.store.createAlternative(
      targetId: 'chat-assistant',
      assistantId: 'interrupted',
    );
    await f.store.updateMessage(
      interrupted.copyWith(status: MessageStatus.interrupted),
    );
    await f.store.selectTip('chat', 'chat-assistant');
    await f.store.enqueuePrompt(
      QueuedPrompt(
        id: 'followup',
        imageReferences: const [],
        documents: const [],
        conversationId: 'chat',
        text: 'Follow the useful answer',
        parentId: 'chat-assistant',
        tracksParent: true,
        createdAt: DateTime.now(),
      ),
    );
    final claim = await f.store.claimQueuedPrompt(
      'chat',
      userMessageId: 'queued-user',
      assistantMessageId: 'queued-answer',
    );
    expect(claim!.userMessage.parentId, 'chat-assistant');
    expect(claim.assistantMessage.parentId, 'queued-user');
    await f.store.restoreQueuedPrompt(claim);
    await f.controller.initialize();
    await f.controller.openConversation('chat');
    await f.controller.resumeQueue();
    expect(f.requests.last.toString(), contains('Keep this answer'));
    expect(f.requests.last.toString(), isNot(contains('stale')));
    final all = (await f.store.openConversation(
      serverProfileId: 'home',
      id: 'chat',
      allBranches: true,
    ))!;
    expect(
      all.allNodes.singleWhere((m) => m.id == stale.id).status,
      MessageStatus.interrupted,
    );
    expect(all.messages.last.status, MessageStatus.complete);
  });
}
