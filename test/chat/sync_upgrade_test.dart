import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/chat_sync.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/domain/chat_folder.dart';
import 'package:mobollama/domain/message.dart';

import '../support/chat_fixture.dart';

void main() {
  test('offline branch and folder survive inventory adoption, deletion and restart without duplicate recovery copies', () async {
    final old = ChatFixture();
    await old.open();
    addTearDown(old.close);
    await old.seed('shared', content: 'Old-device edit');
    await old.controller.initialize();
    final legacy = await old.controller.exportBackup();
    final other = ChatFixture();
    await other.open(version: 13);
    addTearDown(other.close);
    await other.seed('shared', content: 'Other upgraded device');
    await other.controller.initialize();
    final modern = await other.controller.exportBackup();
    final f = ChatFixture();
    final bridge = _UpgradeMailbox(modern, legacy);
    f.syncBridge = bridge;
    await f.open(version: 13);
    addTearDown(f.close);
    await f.seed('shared', content: 'My offline edit');
    await f.seed('deleted', content: 'Offline work on a remotely deleted chat');
    final alternative = await f.store.createAlternative(
      targetId: 'shared-assistant',
      assistantId: 'offline-alternative',
    );
    await f.store.updateMessage(
      alternative.copyWith(
        status: MessageStatus.complete,
        content: 'Offline alternate answer',
      ),
    );
    await f.store.saveFolder(
      const ChatFolder(
        id: 'empty',
        name: 'Research',
        instructions: 'Be precise',
        revision: 1,
      ),
    );
    await f.settings.saveSyncBaseline({'locally-deleted': 'old-synced-hash'});
    await f.controller.initialize();
    await f.controller.chatSync!.synchronize();
    expect(bridge.puts, isEmpty); // Network collection failed; no partial seed.
    expect(
      (await f.store.openConversation(
        serverProfileId: 'home',
        id: 'shared',
        allBranches: true,
      ))!.allNodes,
      hasLength(3),
    );
    bridge.offline = false;
    bridge.failAck = true;
    await f.controller.chatSync!.synchronize();
    expect(bridge.puts, isEmpty);
    expect(f.controller.chatSync!.error, contains('acknowledgement'));
    final countBefore = (await f.store.listAllConversations()).length;
    await f.controller.shutdown();
    f.controller.dispose();
    bridge.failAck = false;
    f.createController();
    await f.controller.initialize();
    await f.controller.chatSync!.synchronize();
    expect(
      bridge.events.indexOf('finish'),
      greaterThan(bridge.events.indexOf('collect-complete')),
    );
    expect(
      bridge.events.indexOf('put'),
      greaterThan(bridge.events.indexOf('finish')),
    );
    final chats = await f.store.listAllConversations();
    expect(chats.length, greaterThanOrEqualTo(countBefore));
    final snapshots = [
      for (final c in chats)
        (await f.store.openConversation(
          serverProfileId: c.serverProfileId,
          id: c.id,
          allBranches: true,
        ))!,
    ];
    expect(
      snapshots
          .singleWhere((t) => t.conversation.id == 'shared')
          .messages
          .last
          .content,
      'Other upgraded device',
    );
    expect(
      snapshots.where(
        (t) => t.allNodes.any((m) => m.content == 'My offline edit'),
      ),
      hasLength(1),
    );
    expect(
      snapshots
          .singleWhere(
            (t) => t.allNodes.any((m) => m.content == 'My offline edit'),
          )
          .allNodes
          .any((m) => m.content == 'Offline alternate answer'),
      isTrue,
    );
    expect(
      snapshots.where(
        (t) => t.allNodes.any((m) => m.content == 'Old-device edit'),
      ),
      hasLength(1),
    );
    expect(chats.any((c) => c.id == 'deleted'), isFalse);
    expect(chats.any((c) => c.id == 'locally-deleted'), isFalse);
    expect(
      bridge.puts
          .where((p) => p['id'] == 'chat:locally-deleted')
          .single['deleted'],
      true,
    );
    expect(f.controller.folders.any((f) => f.id == 'arrived-late'), isTrue);
    expect(
      snapshots.where(
        (t) => t.allNodes.any(
          (m) => m.content == 'Offline work on a remotely deleted chat',
        ),
      ),
      hasLength(1),
    );
    expect(bridge.puts.any((p) => p['id'] == 'folder:empty'), isTrue);
    for (final put in bridge.puts) {
      final json = put['json'] as String?;
      if (json != null) expect((jsonDecode(json) as Map)['version'], 2);
    }
    final count = chats.length;
    await f.controller.chatSync!.synchronize();
    expect((await f.store.listAllConversations()).length, count);
  });
}

/// Models only a durable native mailbox and a failed collection/ack seam.
/// CloudKit transport and cross-device propagation require device acceptance.
class _UpgradeMailbox extends ChatSyncBridge {
  _UpgradeMailbox(this.modern, this.legacy) : super(supportedPlatform: false);
  final String modern, legacy;
  bool caughtUp = false;
  bool offline = true, ready = false, done = false, failAck = false;
  final changes = <ChatSyncChange>[];
  final puts = <Map<String, Object?>>[];
  final events = <String>[];
  ChatSyncState get state => ChatSyncState(
    accountScope: 'a',
    supported: true,
    enabled: true,
    migrationPending: !done,
    inventoryReady: ready,
  );
  @override
  Future<ChatSyncState> initialize() async => state;
  @override
  Future<ChatSyncState> status() async => state;
  @override
  Future<ChatSyncState> collectMigration() async {
    if (offline) throw StateError('Network unavailable');
    if (!ready) {
      changes.addAll([
        ChatSyncChange(
          token: 'old-locally-deleted',
          id: 'chat:locally-deleted',
          json: legacy.replaceAll('shared', 'locally-deleted'),
          deleted: false,
          conflict: false,
          source: 'legacy',
          accountScope: 'a',
        ),

        ChatSyncChange(
          token: 'v2-chat',
          id: 'chat:shared',
          json: modern,
          deleted: false,
          conflict: false,
          source: 'v2',
          accountScope: 'a',
        ),
        const ChatSyncChange(
          token: 'v2-deleted',
          id: 'chat:deleted',
          deleted: true,
          conflict: false,
          source: 'v2',
          accountScope: 'a',
        ),
        ChatSyncChange(
          token: 'old-chat',
          id: 'chat:shared',
          json: legacy,
          deleted: false,
          conflict: false,
          source: 'legacy',
          accountScope: 'a',
        ),
      ]);
      ready = true;
      events.add('collect-complete');
    }
    return state;
  }

  @override
  Future<ChatSyncState> finishMigration() async {
    expect(changes, isEmpty);
    if (!caughtUp) {
      caughtUp = true;
      changes.add(
        ChatSyncChange(
          token: 'late-folder',
          id: 'folder:arrived-late',
          json: jsonEncode({
            'format': 'mobilellama-folder',
            'version': 2,
            'folder': {
              'id': 'arrived-late',
              'name': 'From another device',
              'instructions': '',
              'revision': 1,
              'deleted': false,
            },
          }),
          deleted: false,
          conflict: false,
          source: 'v2',
          accountScope: 'a',
        ),
      );
      return state;
    }
    done = true;
    events.add('finish');
    return state;
  }

  @override
  Future<ChatSyncChange?> nextChange() async => changes.firstOrNull;
  @override
  Future<void> acknowledge(String token) async {
    if (failAck) throw StateError('Lost acknowledgement');
    changes.removeWhere((c) => c.token == token);
  }

  @override
  Future<void> put(String id, {String? json, bool deleted = false}) async {
    expect(done, isTrue);
    events.add('put');
    puts.add({'id': id, 'json': json, 'deleted': deleted});
  }

  @override
  Future<ChatSyncState> sync() async => state;
}
