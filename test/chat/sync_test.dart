import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/chat_sync.dart';
import 'package:mobollama/domain/queued_prompt.dart';

import '../support/chat_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'sync publishes committed history and excludes draft text and credentials',
    () async {
      final fixture = ChatFixture();
      final bridge = _Mailbox();
      fixture.syncBridge = bridge;
      await fixture.open();
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      fixture.controller.setDraftText('Unsent private draft');
      await fixture.controller.chatSync!.synchronize();
      expect(bridge.puts, isEmpty);
      expect(await fixture.controller.send('Committed message'), isTrue);
      fixture.controller.setDraftText('Unsent follow-up');
      await fixture.controller.chatSync!.synchronize();
      expect(bridge.puts, hasLength(1));
      final snapshot = bridge.puts.single['json'] as String;
      expect(snapshot, contains('Committed message'));
      expect(snapshot, isNot(contains('Unsent follow-up')));
      expect(snapshot, isNot(contains('apiKey')));
      final parsed = jsonDecode(snapshot) as Map;
      expect(parsed['conversations'], hasLength(1));
      bridge.puts.clear();
      await fixture.controller.chatSync!.synchronize();
      expect(bridge.puts, isEmpty);
    },
  );

  test('restart after database apply and failed cloud acknowledgement does not duplicate a chat', () async {
    final source = ChatFixture();
    await source.open();
    addTearDown(source.close);
    await source.seed('remote-chat', title: 'From another device');
    await source.controller.initialize();
    final snapshot = await source.controller.exportBackup();

    final target = ChatFixture();
    final bridge = _Mailbox()..failAcknowledgement = true;
    bridge.changes.add(
      ChatSyncChange(
        token: 'receipt-1',
        id: 'remote-chat',
        deleted: false,
        conflict: false,
        json: snapshot,
      ),
    );
    target.syncBridge = bridge;
    await target.open();
    addTearDown(target.close);
    await target.controller.initialize();
    await target.controller.chatSync!.synchronize();
    expect(target.controller.history, hasLength(1));
    expect(await target.store.hasSyncReceipt('receipt-1'), isTrue);
    expect(bridge.changes, hasLength(1));
    expect(target.controller.chatSync!.error, contains('acknowledgement'));
    await target.controller.shutdown();
    target.controller.dispose();
    bridge.failAcknowledgement = false;
    target.createController();
    await target.controller.initialize();
    await target.controller.chatSync!.synchronize();
    expect(target.controller.history, hasLength(1));
    expect(target.controller.history.single.id, 'remote-chat');
    expect(bridge.changes, isEmpty);
    expect(bridge.puts, isEmpty);
  });

  test('restart after native enable rebuilds the account baseline', () async {
    final fixture = ChatFixture();
    final bridge = _Mailbox();
    fixture.syncBridge = bridge;
    await fixture.open();
    addTearDown(fixture.close);
    await fixture.seed('local-chat');
    await fixture.controller.initialize();
    await fixture.controller.chatSync!.synchronize();
    expect(bridge.puts, hasLength(1));
    expect(await fixture.controller.chatSync!.setEnabled(false), isTrue);
    bridge.failEnableAfterCommit = true;
    expect(await fixture.controller.chatSync!.setEnabled(true), isFalse);
    expect(bridge.enabled, isTrue);
    await fixture.controller.shutdown();
    fixture.controller.dispose();
    bridge.puts.clear();
    fixture.createController();
    await fixture.controller.initialize();
    await fixture.controller.chatSync!.synchronize();
    expect(bridge.puts, hasLength(1));
    expect(bridge.puts.single['id'], 'local-chat');
  });

  test('a remote deletion waits for a durable pending queue', () async {
    final fixture = ChatFixture();
    final bridge = _Mailbox();
    fixture.syncBridge = bridge;
    await fixture.open();
    addTearDown(fixture.close);
    await fixture.seed('queued-chat');
    await fixture.store.enqueuePrompt(
      QueuedPrompt(
        id: 'pending-prompt',
        conversationId: 'queued-chat',
        text: 'Keep my queued follow-up',
        imageReferences: const [],
        documents: const [],
        createdAt: DateTime.now().toUtc(),
      ),
    );
    bridge.changes.add(
      const ChatSyncChange(
        token: 'queued-delete',
        id: 'queued-chat',
        deleted: true,
        conflict: false,
      ),
    );
    await fixture.controller.initialize();
    await fixture.controller.openConversation('queued-chat');
    await fixture.controller.chatSync!.synchronize();
    expect(
      fixture.controller.queuedPrompts.single.text,
      'Keep my queued follow-up',
    );
    expect(
      (await fixture.store.loadQueuedPrompts()).single.id,
      'pending-prompt',
    );
    expect(await fixture.store.hasSyncReceipt('queued-delete'), isFalse);
    await fixture.controller.removeQueuedPrompt('pending-prompt');
    await fixture.controller.chatSync!.synchronize();
    expect(fixture.controller.history, isEmpty);
    expect(await fixture.store.hasSyncReceipt('queued-delete'), isTrue);
  });

  test(
    'a remote deletion waits for an unsent draft instead of losing it',
    () async {
      final fixture = ChatFixture();
      final bridge = _Mailbox();
      fixture.syncBridge = bridge;
      await fixture.open();
      addTearDown(fixture.close);
      await fixture.seed('draft-chat');
      await fixture.controller.initialize();
      await fixture.controller.openConversation('draft-chat');
      fixture.controller.setDraftText('Keep my draft');
      bridge.changes.add(
        const ChatSyncChange(
          token: 'delete-receipt',
          id: 'draft-chat',
          deleted: true,
          conflict: false,
        ),
      );
      await fixture.controller.chatSync!.synchronize();
      expect(fixture.controller.history, hasLength(1));
      expect(fixture.controller.draftText, 'Keep my draft');
      expect(fixture.controller.chatSync!.error, contains('local draft'));
      expect(await fixture.store.hasSyncReceipt('delete-receipt'), isFalse);
      await fixture.controller.discardCurrentDraft();
      await fixture.controller.chatSync!.synchronize();
      expect(fixture.controller.history, isEmpty);
      expect(await fixture.store.hasSyncReceipt('delete-receipt'), isTrue);
      expect(bridge.changes, isEmpty);
    },
  );
}

/// Only a platform inbox/acknowledgement fixture. It implements no cloud merge
/// logic and makes no claim about CKSyncEngine propagation between devices.
class _Mailbox extends ChatSyncBridge {
  _Mailbox() : super(supportedPlatform: false);
  final changes = <ChatSyncChange>[];
  final puts = <Map<String, Object?>>[];
  bool failAcknowledgement = false;
  bool enabled = true;
  bool failEnableAfterCommit = false;
  @override
  Future<ChatSyncState> initialize() => status();
  @override
  Future<ChatSyncState> status() async =>
      ChatSyncState(supported: true, enabled: enabled, pending: changes.length);
  @override
  Future<ChatSyncState> enable() async {
    enabled = true;
    if (failEnableAfterCommit) throw StateError('Restart after native enable');
    return status();
  }

  @override
  Future<ChatSyncState> disable() async {
    enabled = false;
    return status();
  }

  @override
  Future<ChatSyncState> sync() => status();
  @override
  Future<void> put(String id, {String? json, bool deleted = false}) async {
    puts.add({'id': id, 'json': json, 'deleted': deleted});
  }

  @override
  Future<ChatSyncChange?> nextChange() async => changes.firstOrNull;
  @override
  Future<void> acknowledge(String token) async {
    if (failAcknowledgement) throw StateError('Cloud acknowledgement failed');
    changes.removeWhere((change) => change.token == token);
  }
}
