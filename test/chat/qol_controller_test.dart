import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/chat/background_execution.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/queued_prompt.dart';

import '../support/chat_fixture.dart';

Future<void> until(bool Function() condition) async {
  for (var attempt = 0; attempt < 1000; attempt++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('The expected chat workflow did not finish.');
}

class BackgroundGrants implements ChatBackgroundExecution {
  final callbacks = <String, ChatBackgroundExpiration>{};
  final ended = <String>[];
  @override
  Future<void> begin(
    String runId, {
    required ChatBackgroundExpiration onExpiration,
  }) async {
    callbacks[runId] = onExpiration;
  }

  @override
  Future<void> end(String runId) async {
    callbacks.remove(runId);
    ended.add(runId);
  }

  @override
  Future<void> dispose() async {
    callbacks.clear();
  }
}

class HeldClaimStore extends ConversationStore {
  HeldClaimStore(super.database);
  final claimed = Completer<void>();
  final release = Completer<void>();
  @override
  Future<QueuedPromptClaim?> claimQueuedPrompt(
    String conversationId, {
    required String userMessageId,
    required String assistantMessageId,
    DateTime? now,
  }) async {
    final result = await super.claimQueuedPrompt(
      conversationId,
      userMessageId: userMessageId,
      assistantMessageId: assistantMessageId,
      now: now,
    );
    if (!claimed.isCompleted) claimed.complete();
    await release.future;
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Stop while SQLite is claiming a prompt prevents transport startup',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      f.controller.dispose();
      final store = HeldClaimStore(SqfliteDatabaseAdapter(f.database));
      f.store = store;
      f.createController();
      await f.controller.initialize();
      final sending = f.controller.send('Stop before the request');
      await store.claimed.future;
      expect(
        await f.controller.deleteConversation(f.controller.conversation!.id),
        isFalse,
      );
      await f.controller.stop();
      store.release.complete();
      expect(await sending, isTrue);
      expect(f.requests, isEmpty);
      expect(f.controller.queuePaused, isTrue);
      expect(f.controller.queuedPrompts.single.text, 'Stop before the request');
    },
  );

  test('shutdown waits for an atomic queue claim to be restored', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    f.controller.dispose();
    final store = HeldClaimStore(SqfliteDatabaseAdapter(f.database));
    f.store = store;
    f.createController();
    await f.controller.initialize();
    final sending = f.controller.send('Keep through shutdown');
    await store.claimed.future;
    var closed = false;
    final shutdown = f.controller.shutdown().then((_) => closed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(closed, isFalse);
    store.release.complete();
    await shutdown;
    expect(await sending, isTrue);
    expect(f.requests, isEmpty);
    expect(
      (await store.loadQueuedPrompts()).single.text,
      'Keep through shutdown',
    );
    expect(f.controller.messages, isEmpty);
  });

  test(
    'queued prompts edit, reorder and remove while another server chat runs',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      f.holdResponse = true;
      final first = f.controller.send('First in A');
      await until(() => f.responseControls.length == 1);
      final chatA = f.controller.conversation!.id;
      expect(f.controller.history.single.title, 'First in A');
      expect(await f.controller.send('Remove this'), isTrue);
      expect(await f.controller.send('Edit this'), isTrue);
      final pending = f.controller.queuedPrompts;
      await f.controller.editQueuedPrompt(pending.last.id, 'A follow-up');
      await f.controller.reorderQueuedPrompts([
        pending.last.id,
        pending.first.id,
      ]);
      expect(f.controller.queuedPrompts.map((item) => item.text), [
        'A follow-up',
        'Remove this',
      ]);
      await f.controller.removeQueuedPrompt(pending.first.id);
      expect(f.requests, hasLength(1));

      expect(await f.controller.newConversationOnServer('lab'), isTrue);
      f.holdResponse = false;
      expect(await f.controller.send('Independent B'), isTrue);
      final chatB = f.controller.conversation!.id;
      f.controller.setDraftText('Keep B draft');
      f.responseControls.first.complete();
      expect(await first, isTrue);
      await until(
        () =>
            f.requests.length == 3 &&
            !f.controller.isConversationRunning(chatA),
      );

      expect(f.requests.map((request) => request['host']), [
        'home.test',
        'lab.test',
        'home.test',
      ]);
      expect(f.controller.conversation!.id, chatB);
      expect(f.controller.draftText, 'Keep B draft');
      expect(
        f.controller.messages
            .where((m) => m.role == MessageRole.user)
            .map((m) => m.content),
        ['Independent B'],
      );
      final storedA = await f.store.openConversation(
        serverProfileId: 'home',
        id: chatA,
      );
      expect(
        storedA!.messages
            .where((m) => m.role == MessageRole.user)
            .map((m) => m.content),
        ['First in A', 'A follow-up'],
      );
      expect(storedA.messages.last.status, MessageStatus.complete);
      expect(await f.store.loadQueuedPrompts(), isEmpty);
    },
  );

  test('Stop and restart preserve the queue until explicit Resume', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.controller.initialize();
    f.holdResponse = true;
    final active = f.controller.send('First');
    await until(() => f.responseControls.isNotEmpty);
    final id = f.controller.conversation!.id;
    await f.controller.send('Second');
    await f.controller.send('Third');
    await f.controller.stop();
    await active;
    expect(f.controller.queuePaused, isTrue);
    expect(f.requests, hasLength(1));
    await f.controller.shutdown();
    f.controller.dispose();
    f.createController();
    await f.controller.initialize();
    await f.controller.openConversation(id);
    expect(f.controller.queuedPrompts.map((item) => item.text), [
      'Second',
      'Third',
    ]);
    expect(f.controller.queuePaused, isTrue);
    expect(f.requests, hasLength(1));
    f.holdResponse = false;
    await f.controller.resumeQueue();
    await until(() => f.requests.length == 3 && !f.controller.isStreaming);
    expect(f.controller.messages.last.status, MessageStatus.complete);
    expect(f.controller.queuedPrompts, isEmpty);
  });

  test('a new Send after Stop starts when there is no parked queue', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.controller.initialize();
    f.holdResponse = true;
    final first = f.controller.send('First');
    await until(() => f.responseControls.isNotEmpty);
    await f.controller.stop();
    await first;
    expect(f.controller.queuedPrompts, isEmpty);
    f.holdResponse = false;
    expect(await f.controller.send('Start a new response'), isTrue);
    expect(f.requests, hasLength(2));
    expect(f.controller.queuedPrompts, isEmpty);
    expect(f.controller.messages.last.status, MessageStatus.complete);
  });

  test(
    'a queued startup failure restores the prompt and waits for Resume',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      f.holdResponse = true;
      final first = f.controller.send('First');
      await until(() => f.responseControls.isNotEmpty);
      await f.controller.send('Keep after failure');
      f.failNextResponses = 1;
      f.responseControls.first.complete();
      await first;
      await until(() => f.requests.length == 2 && !f.controller.isStreaming);
      expect(f.controller.queuePaused, isTrue);
      expect(f.controller.queuedPrompts.single.text, 'Keep after failure');
      expect(f.controller.messages, hasLength(2));
      f.holdResponse = false;
      await f.controller.resumeQueue();
      expect(f.controller.queuedPrompts, isEmpty);
      expect(f.controller.messages, hasLength(4));
      expect(f.controller.messages.last.status, MessageStatus.complete);
    },
  );

  test(
    'backgrounding preserves both runs; expiration cancels only its owner',
    () async {
      final grants = BackgroundGrants();
      final f = ChatFixture()..backgroundExecution = grants;
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      f.holdResponse = true;
      final first = f.controller.send('A');
      await until(() => f.responseControls.length == 1);
      final a = f.controller.conversation!.id;
      final expireA = grants.callbacks.values.single;
      await f.controller.send('A queued');
      await f.controller.newConversationOnServer('lab');
      final second = f.controller.send('B');
      await until(() => f.responseControls.length == 2);
      final b = f.controller.conversation!.id;
      await f.controller.pauseForBackground();
      expect(f.controller.isConversationRunning(a), isTrue);
      expect(f.controller.isConversationRunning(b), isTrue);
      await expireA();
      await first;
      expect(f.controller.isConversationRunning(a), isFalse);
      expect(f.controller.isConversationRunning(b), isTrue);
      expect(f.controller.errorMessage, isNull);
      f.responseControls.last.complete();
      await second;
      expect(grants.callbacks, isEmpty);
      expect(grants.ended, hasLength(2));
      await f.controller.openConversation(a);
      expect(f.controller.messages.last.status, MessageStatus.interrupted);
      expect(f.controller.queuePaused, isTrue);
      expect(f.controller.errorMessage, contains('Background time expired'));
    },
  );

  test(
    'multiple image drafts survive restart and removal preserves other images',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      await f.controller.selectModel('gemma3:4b');
      await f.controller.pickImage();
      await f.controller.pickImage();
      await f.controller.pickImage();
      final images = f.controller.pendingImageReferences;
      expect(images.toSet(), hasLength(3));
      await f.controller.removePendingImage(images[1]);
      expect(f.images.deleted, contains(images[1]));
      expect(f.images.deleted, isNot(contains(images[0])));
      await f.controller.shutdown();
      f.controller.dispose();
      f.createController();
      await f.controller.initialize();
      expect(f.controller.pendingImageReferences, [images[0], images[2]]);
      await f.controller.selectModel('gemma3:4b');
      expect(await f.controller.send('Compare these images'), isTrue);
      expect(f.controller.messages.first.imageReferences, [
        images[0],
        images[2],
      ]);
      final requestMessages = f.requests.single['messages'] as List;
      expect((requestMessages.last as Map)['images'], hasLength(2));
      expect(f.controller.pendingImageReferences, isEmpty);
    },
  );
}
