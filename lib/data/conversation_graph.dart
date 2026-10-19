part of 'conversation_store.dart';

extension ConversationGraphStorage on ConversationStore {
  Future<void> _migrateGraph(SqliteDatabase db) async {
    // SQLite's generalized ALTER TABLE sequence removes only the global
    // position uniqueness constraint; foreign keys are checked before commit.
    await db.execute('''CREATE TABLE messages_next(
      id TEXT PRIMARY KEY,
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      position INTEGER NOT NULL,
      role TEXT NOT NULL CHECK(role IN ('system','user','assistant','tool')),
      status TEXT NOT NULL CHECK(status IN ('queued','streaming','complete','partial','interrupted','failed')),
      content TEXT NOT NULL, reasoning TEXT, created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL, provider_transcript_json TEXT,
      documents_json TEXT NOT NULL DEFAULT '[]', parent_id TEXT,
      sibling_order INTEGER NOT NULL DEFAULT 0)''');
    await db.execute(
      '''INSERT INTO messages_next SELECT m.id,m.conversation_id,m.position,m.role,m.status,m.content,m.reasoning,m.created_at,m.updated_at,m.provider_transcript_json,m.documents_json,
      (SELECT p.id FROM messages p WHERE p.conversation_id=m.conversation_id AND p.position<m.position ORDER BY p.position DESC LIMIT 1),0 FROM messages m''',
    );
    final before = await db.query('SELECT COUNT(*) AS n FROM messages');
    final after = await db.query('SELECT COUNT(*) AS n FROM messages_next');
    if (before.single['n'] != after.single['n']) {
      throw StateError('Message migration did not preserve all messages.');
    }
    await db.execute('DROP TABLE messages');
    await db.execute('ALTER TABLE messages_next RENAME TO messages');
    await db.execute(
      'CREATE INDEX messages_in_conversation ON messages(conversation_id,position,created_at,id)',
    );
    await db.execute(
      'CREATE INDEX message_children ON messages(conversation_id,parent_id,sibling_order,id)',
    );
    for (final definition in [
      'active_tip_id TEXT',
      'folder_id TEXT',
      "instruction_source TEXT NOT NULL DEFAULT 'legacySnapshot'",
      'instruction_source_id TEXT',
      'instruction_source_revision INTEGER',
    ]) {
      await db.execute('ALTER TABLE conversations ADD COLUMN $definition');
    }
    await db.execute(
      '''UPDATE conversations SET active_tip_id=(SELECT id FROM messages WHERE conversation_id=conversations.id ORDER BY position DESC LIMIT 1)''',
    );
    await db.execute('ALTER TABLE queued_prompts ADD COLUMN parent_id TEXT');
    await db.execute(
      'ALTER TABLE queued_prompts ADD COLUMN tracks_parent INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'UPDATE queued_prompts SET parent_id=(SELECT active_tip_id FROM conversations WHERE id=conversation_id),tracks_parent=1',
    );
    await db.execute(
      'CREATE TABLE folders(id TEXT PRIMARY KEY,name TEXT NOT NULL,instructions TEXT NOT NULL,revision INTEGER NOT NULL,deleted INTEGER NOT NULL DEFAULT 0)',
    );
    await db.execute(
      'CREATE TABLE folder_conflicts(fingerprint TEXT PRIMARY KEY,data_json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE checkpoint_branches(conversation_id TEXT PRIMARY KEY REFERENCES conversations(id) ON DELETE CASCADE,tip_id TEXT)',
    );
    await db.execute(
      'CREATE TABLE sync_migration(id TEXT PRIMARY KEY,data_json TEXT NOT NULL)',
    );
    await db.execute(
      "INSERT INTO sync_migration VALUES('phase','{\"phase\":\"oldWritesStopped\"}')",
    );
    for (final chat in await db.query('SELECT * FROM conversations')) {
      final id = chat['id'] as String;
      final rows = await db.query(
        'SELECT * FROM messages WHERE conversation_id=? ORDER BY position',
        [id],
      );
      final messages = await _messagesFromRows(db, rows);
      final checkpoint = await db.query(
        'SELECT * FROM recovery_checkpoints WHERE conversation_id=?',
        [id],
      );
      if (checkpoint.isEmpty) continue;
      final old = _decodeCheckpointMessages(checkpoint.single['messages_json']);
      final divergence = ConversationStore._readInt(
        checkpoint.single['from_position'],
      );
      var parent = messages
          .where((m) => m.position < divergence)
          .lastOrNull
          ?.id;
      final callIds = <String, String>{};
      final nodes = {for (final m in messages) m.id: m};
      var retained = 0;
      for (final message in old) {
        final existing = nodes[message.id];
        final same =
            existing != null &&
            existing.parentId == parent &&
            _sameCheckpointContent(existing, message);
        if (same) {
          parent = existing.id;
          retained++;
          continue;
        }
        final nodeId = nodes.containsKey(message.id)
            ? const Uuid().v4()
            : message.id;
        for (final call in message.toolCalls) {
          callIds[call.id] = const Uuid().v4();
        }
        final node = Message(
          id: nodeId,
          conversationId: id,
          position: message.position,
          parentId: parent,
          siblingOrder: await _nextSiblingOrder(db, id, parent),
          role: message.role,
          status: message.status,
          content: message.content,
          reasoning: message.reasoning,
          providerTranscriptJson: message.providerTranscriptJson,
          imageReferences: message.imageReferences,
          documents: [
            for (final d in message.documents)
              DocumentAttachment(
                id: const Uuid().v4(),
                name: d.name,
                mimeType: d.mimeType,
                reference: d.reference,
                text: d.text,
              ),
          ],
          toolCalls: [
            for (final call in message.toolCalls)
              ToolCall(
                id: callIds[call.id]!,
                name: call.name,
                arguments: call.arguments,
              ),
          ],
          toolResults: [
            for (final result in message.toolResults)
              ToolResult(
                id: const Uuid().v4(),
                toolCallId: callIds[result.toolCallId] ?? result.toolCallId,
                content: result.content,
                isError: result.isError,
              ),
          ],
          createdAt: message.createdAt,
          updatedAt: message.updatedAt,
        );
        await _insertGraphMessage(db, node);
        await _replaceMessageParts(db, node);
        nodes[nodeId] = node;
        parent = nodeId;
        retained++;
      }
      if (retained != old.length) {
        throw StateError('Recovery checkpoint conversion was incomplete.');
      }
      final graph = MessageGraph(nodes.values);
      final restored = graph.branch(parent).skip(divergence).toList();
      if (restored.length != old.length ||
          ConversationStore._referencesInMessages(restored)
              .difference(ConversationStore._referencesInMessages(old))
              .isNotEmpty ||
          ConversationStore._referencesInMessages(old)
              .difference(ConversationStore._referencesInMessages(restored))
              .isNotEmpty) {
        throw StateError('Recovery checkpoint attachments were not preserved.');
      }
      await db.execute('INSERT INTO checkpoint_branches VALUES(?,?)', [
        id,
        parent,
      ]);
    }
    if ((await db.query('PRAGMA foreign_key_check')).isNotEmpty) {
      throw StateError('History migration failed its foreign-key check.');
    }
  }

  bool _sameCheckpointContent(Message a, Message b) {
    Map<String, Object?> value(Message message) =>
        _encodeCheckpointMessage(message)
          ..remove('updatedAt')
          ..remove('createdAt');
    return jsonEncode(value(a)) == jsonEncode(value(b));
  }

  Future<int> _nextSiblingOrder(
    SqliteDatabase db,
    String chat,
    String? parent,
  ) async => ConversationStore._readInt(
    (await db.query(
      'SELECT COALESCE(MAX(sibling_order),-1)+1 AS n FROM messages WHERE conversation_id=? AND parent_id IS ?',
      [chat, parent],
    )).single['n'],
  );

  Future<List<Map<String, Object?>>> _branchRows(
    SqliteDatabase db,
    String chat,
    String? tip, {
    String? before,
    int? limit,
  }) => db.query(
    '''WITH RECURSIVE branch AS (
    SELECT * FROM messages WHERE conversation_id=? AND id=?
    UNION SELECT m.* FROM messages m JOIN branch b ON m.id=b.parent_id WHERE m.conversation_id=?
    ) SELECT * FROM branch ${before == null ? '' : 'WHERE position < (SELECT position FROM messages WHERE id=?)'} ORDER BY position ${limit == null ? 'ASC' : 'DESC'} ${limit == null ? '' : 'LIMIT ?'}''',
    [chat, tip, chat, if (before != null) before, if (limit != null) limit],
  );

  Future<void> _insertGraphMessage(SqliteDatabase db, Message message) =>
      db.execute(
        '''INSERT INTO messages(id,conversation_id,position,role,status,content,reasoning,provider_transcript_json,documents_json,created_at,updated_at,parent_id,sibling_order) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)''',
        [
          message.id,
          message.conversationId,
          message.position,
          message.role.name,
          message.status.name,
          message.content,
          message.reasoning,
          message.providerTranscriptJson,
          _encodeDocuments(message.documents),
          ConversationStore._toEpoch(message.createdAt),
          ConversationStore._toEpoch(message.updatedAt),
          message.parentId,
          message.siblingOrder,
        ],
      );

  Future<List<String>> _replaceGraphTail(
    String chat,
    int from,
    Message? replacement,
  ) => _database.transaction((db) async {
    final row = (await db.query('SELECT * FROM conversations WHERE id=?', [
      chat,
    ])).single;
    final path = await _messagesFromRows(
      db,
      await _branchRows(db, chat, row['active_tip_id'] as String?),
    );
    if (from < 0 || from >= path.length) throw RangeError.value(from);
    final parent = from == 0 ? null : path[from - 1].id;
    String? tip = parent;
    if (replacement != null) {
      final used = (await db.query('SELECT id FROM messages WHERE id=?', [
        replacement.id,
      ])).isNotEmpty;
      final node = replacement.copyWith(
        documents: [
          for (final d in replacement.documents)
            DocumentAttachment(
              id: const Uuid().v4(),
              name: d.name,
              mimeType: d.mimeType,
              reference: d.reference,
              text: d.text,
            ),
        ],
        id: used ? const Uuid().v4() : replacement.id,
        parentId: parent,
        siblingOrder: await _nextSiblingOrder(db, chat, parent),
      );
      await _insertGraphMessage(db, node);
      await _replaceMessageParts(db, node);
      tip = node.id;
    }
    await db.execute(
      'UPDATE conversations SET active_tip_id=?,updated_at=? WHERE id=?',
      [tip, ConversationStore._toEpoch(DateTime.now()), chat],
    );
    await _updateTitleAfterTailChange(
      db,
      chat,
      explicitlyRenamed: row['is_renamed'] == 1,
    );
    return <String>[]; // Every old branch still owns all its attachments.
  });

  Future<Message> createAlternative({
    required String targetId,
    required String assistantId,
    String? editedText,
    String? editedId,
  }) => _database.transaction((db) async {
    if (!_graphEnabled) throw StateError('Message versions are not enabled.');
    final target = await _messageFromDatabase(
      db,
      (await db.query('SELECT * FROM messages WHERE id=?', [targetId])).single,
    );
    final chat = target.conversationId;
    final row = (await db.query(
      'SELECT active_tip_id FROM conversations WHERE id=?',
      [chat],
    )).single;
    final path = await _branchRows(db, chat, row['active_tip_id'] as String?);
    if (!path.any((node) => node['id'] == targetId)) {
      throw const FormatException(
        'Select this version for continuation before changing it.',
      );
    }
    final now = DateTime.now().toUtc();
    var parent = target.parentId;
    var position = target.position;
    if (editedText != null) {
      if (target.role != MessageRole.user || editedId == null) {
        throw const FormatException('Only user messages can be edited.');
      }
      final edited = target.copyWith(
        id: editedId,
        content: editedText,
        createdAt: now,
        updatedAt: now,
        siblingOrder: await _nextSiblingOrder(db, chat, parent),
        documents: [
          for (final d in target.documents)
            DocumentAttachment(
              id: const Uuid().v4(),
              name: d.name,
              mimeType: d.mimeType,
              reference: d.reference,
              text: d.text,
            ),
        ],
      );
      await _insertGraphMessage(db, edited);
      await _replaceMessageParts(db, edited);
      parent = edited.id;
      position++;
    } else if (target.role != MessageRole.assistant) {
      throw const FormatException('Only answers can be regenerated.');
    }
    final answer = Message(
      id: assistantId,
      conversationId: chat,
      position: position,
      parentId: parent,
      siblingOrder: await _nextSiblingOrder(db, chat, parent),
      role: MessageRole.assistant,
      status: MessageStatus.streaming,
      content: '',
      createdAt: now,
      updatedAt: now,
    );
    await _insertGraphMessage(db, answer);
    await db.execute(
      'UPDATE conversations SET active_tip_id=?,updated_at=? WHERE id=?',
      [answer.id, ConversationStore._toEpoch(now), chat],
    );
    return answer;
  });

  Future<List<Message>> versionsOf(String id) async {
    if (!_graphEnabled) return [];
    final rows = await _database.query('SELECT * FROM messages WHERE id=?', [
      id,
    ]);
    if (rows.isEmpty) return [];
    final row = rows.single;
    return _messagesFromRows(
      _database,
      await _database.query(
        'SELECT * FROM messages WHERE conversation_id=? AND parent_id IS ? AND role=? ORDER BY sibling_order,created_at,id',
        [row['conversation_id'], row['parent_id'], row['role']],
      ),
    );
  }

  Future<void> selectTip(String conversationId, String? tip) =>
      _database.transaction((db) async {
        if (!_graphEnabled) {
          throw StateError('Message versions are not enabled.');
        }
        if (tip != null &&
            (await db.query(
              'SELECT id FROM messages WHERE conversation_id=? AND id=?',
              [conversationId, tip],
            )).isEmpty) {
          throw const FormatException('The selected message is unavailable.');
        }
        await db.execute(
          'UPDATE conversations SET active_tip_id=?,updated_at=? WHERE id=?',
          [tip, ConversationStore._toEpoch(DateTime.now()), conversationId],
        );
      });

  Future<Map<String, dynamic>?> migrationValue(String key) async {
    final rows = await _database.query(
      'SELECT data_json FROM sync_migration WHERE id=?',
      [key],
    );
    return rows.isEmpty
        ? null
        : jsonDecode(rows.single['data_json'] as String)
              as Map<String, dynamic>;
  }

  Future<void> setMigrationValue(String key, Map<String, Object?> value) =>
      _database.execute(
        'INSERT INTO sync_migration VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data_json=excluded.data_json',
        [key, jsonEncode(value)],
      );

  Future<Set<String>> migrationDeletions(String scope) async {
    final rows = await _database.query(
      'SELECT data_json FROM sync_migration WHERE id=?',
      ['deletions:$scope'],
    );
    return rows.isEmpty
        ? {}
        : (jsonDecode(rows.single['data_json'] as String) as Map).keys
              .cast<String>()
              .toSet();
  }

  Future<void> recordMigrationDeletion(String scope, String id) =>
      _database.transaction((db) async {
        final key = 'deletions:$scope';
        final rows = await db.query(
          'SELECT data_json FROM sync_migration WHERE id=?',
          [key],
        );
        final value = rows.isEmpty
            ? <String, dynamic>{}
            : jsonDecode(rows.single['data_json'] as String)
                  as Map<String, dynamic>;
        value[id] = true;
        await db.execute(
          'INSERT INTO sync_migration VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data_json=excluded.data_json',
          [key, jsonEncode(value)],
        );
      });

  Future<void> recordSyncReceipt(String token) => _database.transaction(
    (db) => ConversationStore._insertSyncReceipt(db, token),
  );

  Future<List<ChatFolder>> folders({bool includeDeleted = false}) async => [
    for (final row in await _database.query(
      'SELECT * FROM folders ${includeDeleted ? '' : 'WHERE deleted=0'} ORDER BY name COLLATE NOCASE,id',
    ))
      ChatFolder(
        id: row['id'] as String,
        name: row['name'] as String,
        instructions: row['instructions'] as String,
        revision: row['revision'] as int,
        deleted: row['deleted'] == 1,
      ),
  ];

  Future<void> saveFolder(ChatFolder folder, {String? receipt}) =>
      _database.transaction((db) async {
        if (receipt != null &&
            await ConversationStore._hasSyncReceipt(db, receipt)) {
          return;
        }
        final old = (await db.query('SELECT * FROM folders WHERE id=?', [
          folder.id,
        ])).firstOrNull;
        if (old != null && receipt != null) {
          final original = ChatFolder(
            id: old['id'] as String,
            name: old['name'] as String,
            instructions: old['instructions'] as String,
            revision: old['revision'] as int,
            deleted: old['deleted'] == 1,
          );
          if (original.fingerprint != folder.fingerprint) {
            await db.execute(
              'INSERT OR IGNORE INTO folder_conflicts VALUES(?,?)',
              [original.fingerprint, jsonEncode(original.toJson())],
            );
          }
        }
        await _putFolder(db, folder);
        if (receipt != null) {
          await ConversationStore._insertSyncReceipt(db, receipt);
        }
      });

  Future<void> _putFolder(SqliteDatabase db, ChatFolder folder) async {
    await db.execute(
      'INSERT INTO folders(id,name,instructions,revision,deleted) VALUES(?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET name=excluded.name,instructions=excluded.instructions,revision=excluded.revision,deleted=excluded.deleted',
      [
        folder.id,
        folder.name,
        folder.instructions,
        folder.revision,
        folder.deleted ? 1 : 0,
      ],
    );
    if (folder.deleted) {
      await db.execute(
        'UPDATE conversations SET folder_id=NULL,updated_at=? WHERE folder_id=?',
        [ConversationStore._toEpoch(DateTime.now()), folder.id],
      );
    }
  }

  Future<void> moveToFolder(String conversationId, String? folderId) =>
      _database.transaction((db) async {
        if (folderId != null &&
            (await db.query('SELECT id FROM folders WHERE id=? AND deleted=0', [
              folderId,
            ])).isEmpty) {
          throw const FormatException('This folder no longer exists.');
        }
        await db.execute(
          'UPDATE conversations SET folder_id=?,updated_at=? WHERE id=?',
          [
            folderId,
            ConversationStore._toEpoch(DateTime.now()),
            conversationId,
          ],
        );
      });
}
