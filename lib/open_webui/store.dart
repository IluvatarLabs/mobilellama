import 'dart:convert';

import '../data/conversation_store.dart';
import 'client.dart';

/// Account cache in the application's existing SQLite database. Direct-chat
/// backup/sync tables have no references to these tables.
final class WebUiStore {
  const WebUiStore(this.database);
  final SqliteDatabase database;

  static Future<void> migrateBindings(SqliteDatabase database) =>
      database.execute(
        '''CREATE TABLE remote_profile_bindings(
    profile_id TEXT PRIMARY KEY, server TEXT NOT NULL, user_id TEXT NOT NULL,
    FOREIGN KEY(server,user_id) REFERENCES remote_accounts(server,user_id) ON DELETE CASCADE)''',
      );

  Future<Map<String, dynamic>?> binding(String profileId) async =>
      (await database.query(
        'SELECT server,user_id FROM remote_profile_bindings WHERE profile_id=?',
        [profileId],
      )).firstOrNull;
  Future<List<String>> boundProfiles(String profileId) async {
    final account = await binding(profileId);
    if (account == null) return [profileId];
    return (await database.query(
      'SELECT profile_id FROM remote_profile_bindings WHERE server=? AND user_id=?',
      [account['server'], account['user_id']],
    )).map((row) => row['profile_id'] as String).toList();
  }

  Future<void> clearStoredAccount(String profileId) => database.transaction((
    db,
  ) async {
    final rows = await db.query(
      'SELECT server,user_id FROM remote_profile_bindings WHERE profile_id=?',
      [profileId],
    );
    if (rows.isEmpty) return;
    await db.execute(
      'DELETE FROM remote_accounts WHERE server=? AND user_id=?',
      [rows.first['server'], rows.first['user_id']],
    );
  });

  static Future<void> migrate(SqliteDatabase database) async {
    await database.execute('''CREATE TABLE remote_accounts(
      server TEXT NOT NULL, user_id TEXT NOT NULL, name TEXT NOT NULL,
      PRIMARY KEY(server, user_id))''');
    for (final table in [
      'remote_chats',
      'remote_messages',
      'remote_drafts',
      'remote_intents',
      'remote_queues',
    ]) {
      await database.execute(
        '''CREATE TABLE $table(
        server TEXT NOT NULL, user_id TEXT NOT NULL, id TEXT NOT NULL,
        scope TEXT NOT NULL, data_json TEXT NOT NULL,
        PRIMARY KEY(server, user_id, ${table == 'remote_messages' ? 'scope, ' : ''}id),
        FOREIGN KEY(server, user_id) REFERENCES remote_accounts(server, user_id) ON DELETE CASCADE)''',
      );
      await database.execute(
        'CREATE INDEX ${table}_scope ON $table(server, user_id, scope)',
      );
    }
  }

  Future<Set<String>> stagedReferences(WebUiLease lease) async {
    final paths = <String>{};
    for (final table in ['remote_drafts', 'remote_queues', 'remote_intents']) {
      for (final value in await _read(table, lease)) {
        for (final item
            in ((value['resources'] as Map?)?['uploads'] as List? ?? [])
                .whereType<Map>()) {
          if (item['path'] is String) paths.add(item['path'] as String);
        }
      }
    }
    return paths;
  }

  Future<void> unlock(WebUiLease lease) async {
    lease.check();
    final account = lease.identity;
    await database.transaction((db) async {
      lease.check();
      final binding = await db.query(
        'SELECT server,user_id FROM remote_profile_bindings WHERE profile_id=?',
        [lease.session.profileId],
      );
      if (binding.isNotEmpty &&
          (binding.first['server'] != account.server ||
              binding.first['user_id'] != account.userId)) {
        throw const WebUiException(
          'This connection belongs to a different account. Add a separate connection, or sign out of its saved account first. Its existing drafts remain locked.',
        );
      }
      await db.execute(
        'INSERT INTO remote_accounts(server, user_id, name) VALUES(?, ?, ?) ON CONFLICT(server, user_id) DO UPDATE SET name=excluded.name',
        [account.server, account.userId, account.name],
      );
      await db.execute(
        'INSERT INTO remote_profile_bindings(profile_id,server,user_id) VALUES(?,?,?) ON CONFLICT(profile_id) DO NOTHING',
        [lease.session.profileId, account.server, account.userId],
      );
      lease.check();
    });
  }

  Future<List<Map<String, dynamic>>> chats(WebUiLease lease) =>
      _read('remote_chats', lease);
  Future<Map<String, dynamic>?> draft(WebUiLease lease, String scope) async =>
      (await _read('remote_drafts', lease, id: scope)).firstOrNull;
  Future<List<Map<String, dynamic>>> intents(WebUiLease lease) =>
      _read('remote_intents', lease);
  Future<List<Map<String, dynamic>>> queue(WebUiLease lease, String scope) =>
      _read('remote_queues', lease, scope: scope);
  Future<void> saveDraft(
    WebUiLease lease,
    String scope,
    Map<String, dynamic> data,
  ) => _put('remote_drafts', lease, scope, scope, data);
  Future<void> saveIntent(
    WebUiLease lease,
    String id,
    String scope,
    Map<String, dynamic> data,
  ) => database.transaction((db) async {
    lease.check();
    await _putWith(db, 'remote_intents', lease, id, scope, data);
    // Establishing a server chat and moving its draft are one durable change.
    // A crash must not leave that chat's parent in the next new-chat draft.
    final chatId = data['chatId'];
    if (chatId is String) {
      final newScope = 'new:${lease.session.profileId}';
      final rows = await db.query(
        'SELECT data_json FROM remote_drafts WHERE server=? AND user_id=? AND id=?',
        [lease.identity.server, lease.identity.userId, newScope],
      );
      if (rows.isNotEmpty) {
        final draft = Map<String, dynamic>.from(
          jsonDecode(rows.single['data_json'] as String) as Map,
        );
        if (draft['parentId'] == data['assistantId']) {
          await _putWith(db, 'remote_drafts', lease, chatId, chatId, draft);
          await db.execute(
            'DELETE FROM remote_drafts WHERE server=? AND user_id=? AND id=?',
            [lease.identity.server, lease.identity.userId, newScope],
          );
        }
      }
    }
    final queueId = data['queueId'];
    if (queueId is String) {
      final rows = await db.query(
        'SELECT data_json FROM remote_queues WHERE server=? AND user_id=? AND id=?',
        [lease.identity.server, lease.identity.userId, queueId],
      );
      if (rows.isNotEmpty) {
        final queued = Map<String, dynamic>.from(
          jsonDecode(rows.first['data_json'] as String) as Map,
        );
        await _putWith(db, 'remote_queues', lease, queueId, scope, {
          ...queued,
          'intentId': id,
        });
      }
    }
    lease.check();
  });
  Future<void> saveQueued(
    WebUiLease lease,
    String id,
    String scope,
    Map<String, dynamic> data,
  ) => _put('remote_queues', lease, id, scope, data);

  Future<void> removeQueued(WebUiLease lease, String id) =>
      database.transaction((db) async {
        lease.check();
        await db.execute(
          'DELETE FROM remote_queues WHERE server=? AND user_id=? AND id=?',
          [lease.identity.server, lease.identity.userId, id],
        );
        lease.check();
      });

  Future<void> cacheSummaries(
    WebUiLease lease,
    List<Map<String, dynamic>> entries,
  ) => database.transaction((db) async {
    lease.check();
    for (final entry in entries) {
      final id = entry['id'] as String;
      final rows = await db.query(
        'SELECT data_json FROM remote_chats WHERE server=? AND user_id=? AND id=?',
        [lease.identity.server, lease.identity.userId, id],
      );
      final old = rows.isEmpty
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(
              jsonDecode(rows.first['data_json'] as String) as Map,
            );
      await _putWith(db, 'remote_chats', lease, id, id, {
        ...old,
        ...entry,
        'chat': {
          ...?old['chat'] as Map?,
          'title': entry['title'] ?? (old['chat'] as Map?)?['title'] ?? 'Chat',
        },
        'complete': old['complete'] == true,
      });
      lease.check();
    }
  });

  Future<Map<String, dynamic>> refreshChat(
    WebUiSession session,
    String id,
  ) async {
    final lease = session.capture();
    final response = await session.client.chat(id, lease);
    await cacheChat(lease, response);
    lease.check();
    return response;
  }

  Future<void> cacheChat(
    WebUiLease lease,
    Map<String, dynamic> response,
  ) async {
    lease.check();
    final id = response['id'];
    final rawChat = response['chat'];
    if (id is! String || rawChat is! Map) {
      throw const FormatException('Invalid server chat.');
    }
    final chat = Map<String, dynamic>.from(rawChat);
    final history = chat.remove('history');
    chat.remove('messages');
    final nodes = history is Map ? history['messages'] : null;
    if (nodes is! Map) {
      throw const FormatException('Server chat history is unavailable.');
    }
    await database.transaction((db) async {
      lease.check();
      await _putWith(db, 'remote_chats', lease, id, id, {
        ...response,
        'chat': chat,
        'activeTip':
            response['current_message_id'] is String &&
                nodes.containsKey(response['current_message_id'])
            ? response['current_message_id']
            : history['currentId'],
        'complete': true,
      });
      for (final entry in nodes.entries) {
        if (entry.key is! String || entry.value is! Map) {
          throw const FormatException('Invalid server message.');
        }
        await _putWith(db, 'remote_messages', lease, entry.key as String, id, {
          ...Map<String, dynamic>.from(entry.value as Map),
          'id': entry.key,
        });
        lease.check();
      }
      // Missing nodes are not deletions. Server IDs remain available for
      // reconciliation until an explicit delete clears the cache.
      lease.check();
    });
  }

  Future<Map<String, dynamic>?> chat(WebUiLease lease, String id) async {
    final cached = (await _read('remote_chats', lease, id: id)).firstOrNull;
    if (cached == null) return null;
    final nodes = await _read('remote_messages', lease, scope: id);
    lease.check();
    return {
      ...cached,
      'chat': {
        ...(cached['chat'] as Map),
        'history': {
          'currentId': cached['activeTip'],
          'messages': {for (final node in nodes) node['id']: node},
        },
      },
    };
  }

  Future<void> removeChat(WebUiLease lease, String id) =>
      database.transaction((db) async {
        lease.check();
        for (final table in [
          'remote_chats',
          'remote_messages',
          'remote_drafts',
          'remote_queues',
          'remote_intents',
        ]) {
          await db.execute(
            'DELETE FROM $table WHERE server=? AND user_id=? AND scope=?',
            [lease.identity.server, lease.identity.userId, id],
          );
        }
        lease.check();
      });

  /// Sign-out first locks the session, then removes precisely its partition.
  Future<void> signOut(WebUiSession session) async {
    session.lock();
    await database.execute(
      'DELETE FROM remote_accounts WHERE server=? AND user_id=?',
      [session.identity.server, session.identity.userId],
    );
  }

  /// Only IDs absent from a complete all-view inventory can be removed, and
  /// only if their cache was not changed while that inventory was fetched.
  Future<Map<String, String>> inventorySnapshot(WebUiLease lease) async {
    lease.check();
    final rows = await database.query(
      'SELECT id,data_json FROM remote_chats WHERE server=? AND user_id=?',
      [lease.identity.server, lease.identity.userId],
    );
    lease.check();
    return {
      for (final row in rows) row['id'] as String: row['data_json'] as String,
    };
  }

  Future<void> finishInventory(
    WebUiLease lease,
    Map<String, String> before,
    Set<String> present,
  ) => database.transaction((db) async {
    lease.check();
    for (final entry in before.entries) {
      if (present.contains(entry.key)) continue;
      final args = [lease.identity.server, lease.identity.userId, entry.key];
      final rows = await db.query(
        'SELECT data_json FROM remote_chats WHERE server=? AND user_id=? AND id=?',
        args,
      );
      if (rows.isEmpty || rows.first['data_json'] != entry.value) continue;
      final drafts = await db.query(
        'SELECT data_json FROM remote_drafts WHERE server=? AND user_id=? AND scope=?',
        args,
      );
      final intents = await db.query(
        'SELECT data_json FROM remote_intents WHERE server=? AND user_id=? AND scope=?',
        args,
      );
      final keepDraft = drafts.any((row) {
        final value = jsonDecode(row['data_json'] as String) as Map;
        return (value['text'] as String? ?? '').isNotEmpty ||
            (value['resources'] as Map? ?? {}).isNotEmpty;
      });
      final unsettled = intents.any(
        (row) => !{
          'completed',
          'failed',
          'stopped',
          'dismissed',
        }.contains((jsonDecode(row['data_json'] as String) as Map)['state']),
      );
      if (keepDraft || unsettled) {
        final cached = Map<String, dynamic>.from(
          jsonDecode(entry.value) as Map,
        );
        await _putWith(db, 'remote_chats', lease, entry.key, entry.key, {
          ...cached,
          'missingOnServer': true,
        });
      } else {
        for (final table in ['remote_chats', 'remote_messages']) {
          await db.execute(
            'DELETE FROM $table WHERE server=? AND user_id=? AND scope=?',
            args,
          );
        }
      }
      lease.check();
    }
  });

  Future<List<Map<String, dynamic>>> _read(
    String table,
    WebUiLease lease, {
    String? id,
    String? scope,
  }) async {
    lease.check();
    final rows = await database.query(
      'SELECT data_json FROM $table WHERE server=? AND user_id=? ${id == null ? '' : 'AND id=?'} ${scope == null ? '' : 'AND scope=?'}',
      [
        lease.identity.server,
        lease.identity.userId,
        if (id != null) id,
        if (scope != null) scope,
      ],
    );
    lease.check();
    return rows
        .map(
          (row) => Map<String, dynamic>.from(
            jsonDecode(row['data_json'] as String) as Map,
          ),
        )
        .toList();
  }

  Future<void> _put(
    String table,
    WebUiLease lease,
    String id,
    String scope,
    Map<String, dynamic> data,
  ) => database.transaction((db) async {
    lease.check();
    await _putWith(db, table, lease, id, scope, data);
    lease.check();
  });
  Future<void> _putWith(
    SqliteDatabase db,
    String table,
    WebUiLease lease,
    String id,
    String scope,
    Map<String, dynamic> data,
  ) => db.execute(
    'INSERT INTO $table(server,user_id,id,scope,data_json) VALUES(?,?,?,?,?) ON CONFLICT(server,user_id,${table == 'remote_messages' ? 'scope,' : ''}id) DO UPDATE SET scope=excluded.scope,data_json=excluded.data_json',
    [lease.identity.server, lease.identity.userId, id, scope, jsonEncode(data)],
  );
}
