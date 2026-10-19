import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'chat_sync.dart';
import 'conversation_store.dart';

/// One-time adoption into the existing sync mechanism. Native collection is
/// complete before this runs; each recovery ID is journaled before it is used.
final class ChatSyncMigration {
  const ChatSyncMigration({
    required this.store,
    required this.exportLocal,
    required this.apply,
    required this.allocateId,
  });
  final ConversationStore store;
  final Future<String?> Function(String) exportLocal;
  final Future<void> Function(ChatSyncChange) apply;
  final String Function() allocateId;

  Future<void> adopt(ChatSyncChange change) async {
    if (await store.hasSyncReceipt(change.token)) return;
    final source = change.source;
    final identity = change.id;
    final digest = fingerprint(change.json);
    final key =
        'adoption:${sha256.convert(utf8.encode('${change.accountScope}:$source:$identity:$digest:${change.deleted}'))}';
    final receipt = 'migration:$key';
    final local = await exportLocal(identity);
    final known = await store.migrationValue(
      'inventory:${change.accountScope}:$identity',
    );
    final legacyBaseline = await store.migrationValue('legacyBaseline') ?? {};
    final locallyDeleted =
        source == 'legacyDeletion' ||
        (local == null &&
            identity.startsWith('chat:') &&
            legacyBaseline.containsKey(identity.substring(5))) ||
        (await store.migrationDeletions(change.accountScope))
            .contains(identity);
    if (locallyDeleted) {
      await store.recordMigrationDeletion(change.accountScope, identity);
      if (source == 'v2' && change.json != null) {
        await _recover(key: key, identity: identity, json: change.json!);
      }
      if (local != null) {
        await _recover(key: '$key:local', identity: identity, json: local);
        await apply(
          ChatSyncChange(
            token: change.token,
            id: identity,
            deleted: true,
            conflict: false,
            accountScope: change.accountScope,
          ),
        );
      } else {
        await store.recordSyncReceipt(change.token);
      }
      return;
    }
    if (source == 'v2') {
      // Remember deletions even after the inbox item is acknowledged.
      await store.setMigrationValue(
        'inventory:${change.accountScope}:$identity',
        {'deleted': change.deleted, 'fingerprint': digest},
      );
      if (local != null &&
          (change.deleted || !containsSnapshot(change.json, local))) {
        await _recover(key: '$key:local', identity: identity, json: local);
      }
      if (!change.deleted && local != null && fingerprint(local) == digest) {
        await store.recordSyncReceipt(change.token);
      } else {
        await apply(change);
      }
      return;
    }
    // A legacy generation must never overwrite new-format edits. Identical
    // ancestor data is already retained in the graph and needs no extra copy.
    if (change.json != null &&
        local != null &&
        containsSnapshot(local, change.json)) {
      await store.recordSyncReceipt(change.token);
      return;
    }
    if (known != null || local != null || change.conflict) {
      if (change.json != null) {
        await _recover(key: key, identity: identity, json: change.json!);
      } else if (known == null && local != null) {
        await _recover(key: '$key:local', identity: identity, json: local);
        await apply(change);
      }
      await store.recordSyncReceipt(change.token);
      return;
    }
    if (!change.deleted) {
      // Receipt + data are committed together by the existing importer.
      await apply(change);
    } else {
      await store.recordSyncReceipt(change.token);
    }
    await store.setMigrationValue(receipt, {'adopted': true});
  }

  Future<void> _recover({
    required String key,
    required String identity,
    required String json,
  }) async {
    final recorded = await store.migrationValue(key);
    final prefix = identity.startsWith('folder:') ? 'folder:' : 'chat:';
    final target = recorded?['target'] as String? ?? '$prefix${allocateId()}';
    if (recorded == null) {
      await store.setMigrationValue(key, {'target': target});
    }
    final token = 'recovered:$key';
    if (await store.hasSyncReceipt(token)) return;
    await apply(
      ChatSyncChange(
        token: token,
        id: target,
        deleted: false,
        conflict: true,
        json: json,
      ),
    );
  }

  static String fingerprint(String? json) => sha256
      .convert(
        utf8.encode(
          json == null ? 'deleted' : jsonEncode(_canonical(jsonDecode(json))),
        ),
      )
      .toString();

  static Object? _canonical(Object? value) {
    if (value is List) return value.map(_canonical).toList();
    if (value is Map) {
      final keys =
          value.keys.cast<String>().where((k) => k != 'exportedAt').toList()
            ..sort();
      return {for (final key in keys) key: _canonical(value[key])};
    }
    return value;
  }

  /// v1's linear path can already be present among the v2 graph's nodes.
  /// Ignore only format-derived bookkeeping; content/settings/attachments and
  /// stable message identities must match. Never flatten the stored graph.
  static bool containsSnapshot(String? destination, String? source) {
    if (destination == null || source == null) return false;
    final a = jsonDecode(destination) as Map;
    final b = jsonDecode(source) as Map;
    if (a['format'] != b['format']) return false;
    if (b['version'] == 2) {
      return fingerprint(destination) == fingerprint(source);
    }
    if (a['format'] != 'mobilellama-chat-backup') {
      return fingerprint(destination) == fingerprint(source);
    }
    final ac = Map<String, dynamic>.from(
      (a['conversations'] as List).single as Map,
    );
    final bc = Map<String, dynamic>.from(
      (b['conversations'] as List).single as Map,
    );
    final am = (ac.remove('messages') as List).cast<Map>();
    final bm = (bc.remove('messages') as List).cast<Map>();
    for (final field in [
      'activeTipId',
      'folderId',
      'instructionSource',
      'instructionSourceId',
      'instructionSourceRevision',
      'updatedAt',
    ]) {
      ac.remove(field);
      bc.remove(field);
    }
    if (jsonEncode(_canonical(ac)) != jsonEncode(_canonical(bc))) return false;
    Map<String, dynamic> normalized(
      Map message,
      int index,
      List<Map> path,
      int version,
    ) {
      final result = Map<String, dynamic>.from(message)..remove('siblingOrder');
      if (version == 1) {
        result['parentId'] = index == 0 ? null : path[index - 1]['id'];
      }
      return result;
    }

    final byId = {
      for (var i = 0; i < am.length; i++)
        am[i]['id']: normalized(am[i], i, am, a['version'] as int),
    };
    for (var i = 0; i < bm.length; i++) {
      final value = byId[bm[i]['id']];
      if (value == null ||
          jsonEncode(_canonical(value)) !=
              jsonEncode(
                _canonical(normalized(bm[i], i, bm, b['version'] as int)),
              )) {
        return false;
      }
    }
    return true;
  }
}
