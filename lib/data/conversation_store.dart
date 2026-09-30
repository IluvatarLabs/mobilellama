import 'dart:convert';

import 'attachment_reference_codec.dart';
import '../domain/conversation.dart';
import '../domain/document_attachment.dart';
import '../domain/generation_options.dart';
import '../domain/message.dart';
import '../domain/queued_prompt.dart';
import '../domain/tool_call.dart';

abstract interface class SqliteDatabase {
  Future<void> execute(String sql, [List<Object?> parameters = const []]);

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> parameters = const [],
  ]);

  Future<T> transaction<T>(Future<T> Function(SqliteDatabase database) action);
}

final class ConversationSearchResult {
  const ConversationSearchResult(this.conversation, this.excerpt);
  final Conversation conversation;
  final String? excerpt;
}

class ConversationStore {
  ConversationStore(
    this._database, {
    AttachmentReferenceCodec referenceCodec =
        const IdentityAttachmentReferenceCodec(),
  }) : _referenceCodec = referenceCodec;

  static const schemaVersion = 9;
  final SqliteDatabase _database;
  final AttachmentReferenceCodec _referenceCodec;

  Future<void> migrate({
    required int fromVersion,
    required String legacyServerProfileId,
    int toVersion = schemaVersion,
  }) async {
    if (fromVersion < 0 ||
        toVersion > schemaVersion ||
        fromVersion > toVersion) {
      throw ArgumentError(
        'unsupported schema migration $fromVersion -> $toVersion',
      );
    }

    await _database.execute('PRAGMA foreign_keys = ON');
    if (fromVersion == toVersion) return;
    final legacyProfileId = legacyServerProfileId.trim();
    if (legacyProfileId.isEmpty) {
      throw ArgumentError.value(
        legacyServerProfileId,
        'legacyServerProfileId',
        'must not be empty',
      );
    }

    await _database.transaction((database) async {
      if (fromVersion < 1 && toVersion >= 1) {
        for (final statement in _schemaVersionOne) {
          await database.execute(statement);
        }
        await database.execute('PRAGMA user_version = 1');
      }
      if (fromVersion < 2 && toVersion >= 2) {
        await database.execute('''ALTER TABLE conversations
             ADD COLUMN generation_options_json TEXT NOT NULL DEFAULT '{}' ''');
        await database.execute('PRAGMA user_version = 2');
      }
      if (fromVersion < 3 && toVersion >= 3) {
        await database.execute('''ALTER TABLE conversations
             ADD COLUMN server_profile_id TEXT NOT NULL DEFAULT '' ''');
        await database.execute(
          '''UPDATE conversations SET server_profile_id = ?
             WHERE server_profile_id = '' ''',
          <Object?>[legacyProfileId],
        );
        await database.execute('''CREATE INDEX conversations_by_server_profile
             ON conversations(
               server_profile_id, updated_at DESC, created_at DESC, id ASC
             )''');
        await database.execute('''ALTER TABLE messages
             ADD COLUMN provider_transcript_json TEXT''');
        await database.execute('PRAGMA user_version = 3');
      }
      if (fromVersion < 4 && toVersion >= 4) {
        for (final field in ['is_pinned', 'is_archived', 'is_renamed']) {
          await database.execute(
            'ALTER TABLE conversations ADD COLUMN $field '
            'INTEGER NOT NULL DEFAULT 0 CHECK($field IN (0, 1))',
          );
        }
        await database.execute('PRAGMA user_version = 4');
      }
      if (fromVersion < 5 && toVersion >= 5) {
        await database.execute('''CREATE TABLE chat_drafts(
             scope TEXT PRIMARY KEY,
             data_json TEXT NOT NULL
           )''');
        await database.execute('PRAGMA user_version = 5');
      }
      if (fromVersion < 6 && toVersion >= 6) {
        await database.execute('''ALTER TABLE messages
             ADD COLUMN documents_json TEXT NOT NULL DEFAULT '[]' ''');
        await database.execute('PRAGMA user_version = 6');
      }
      if (fromVersion < 7 && toVersion >= 7) {
        await database.execute('''CREATE TABLE sync_receipts(
             token TEXT PRIMARY KEY
           )''');
        await database.execute('PRAGMA user_version = 7');
      }
      if (fromVersion < 8 && toVersion >= 8) {
        await database.execute('''CREATE TABLE queued_prompts(
             id TEXT PRIMARY KEY,
             conversation_id TEXT NOT NULL
               REFERENCES conversations(id) ON DELETE CASCADE,
             position INTEGER NOT NULL CHECK(position >= 0),
             text TEXT NOT NULL,
             images_json TEXT NOT NULL DEFAULT '[]',
             documents_json TEXT NOT NULL DEFAULT '[]',
             created_at INTEGER NOT NULL,
             UNIQUE(conversation_id, position)
           )''');
        await database.execute('''CREATE INDEX queued_prompts_in_conversation
             ON queued_prompts(
               conversation_id, position ASC, created_at ASC, id ASC
             )''');
        await database.execute('PRAGMA user_version = 8');
      }
      if (fromVersion < 9 && toVersion >= 9) {
        // One local-only recovery snapshot per chat for the latest revision.
        await database.execute('''CREATE TABLE recovery_checkpoints(
             conversation_id TEXT PRIMARY KEY
               REFERENCES conversations(id) ON DELETE CASCADE,
             from_position INTEGER NOT NULL CHECK(from_position >= 0),
             messages_json TEXT NOT NULL,
             created_at INTEGER NOT NULL
           )''');
        await database.execute('PRAGMA user_version = 9');
      }
    });
  }

  Future<Conversation> createConversation({
    required String id,
    required String serverProfileId,
    required String selectedModel,
    required String systemPrompt,
    GenerationOptions generationOptions = const GenerationOptions(),
    DateTime? now,
  }) async {
    final profileId = serverProfileId.trim();
    if (profileId.isEmpty) {
      throw ArgumentError.value(
        serverProfileId,
        'serverProfileId',
        'must not be empty',
      );
    }
    final timestamp = (now ?? DateTime.now()).toUtc();
    final conversation = Conversation(
      id: id,
      serverProfileId: profileId,
      title: 'New chat',
      selectedModel: selectedModel,
      systemPrompt: systemPrompt,
      generationOptions: generationOptions,
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    await _database.execute(
      '''INSERT INTO conversations(
           id, server_profile_id, title, title_from_first_user, selected_model,
           system_prompt, generation_options_json, created_at, updated_at
         ) VALUES(?, ?, ?, 0, ?, ?, ?, ?, ?)''',
      <Object?>[
        conversation.id,
        conversation.serverProfileId,
        conversation.title,
        conversation.selectedModel,
        conversation.systemPrompt,
        jsonEncode(conversation.generationOptions.toOllamaJson()),
        _toEpoch(conversation.createdAt),
        _toEpoch(conversation.updatedAt),
      ],
    );
    return conversation;
  }

  Future<ConversationThread?> openConversation({
    required String serverProfileId,
    required String id,
  }) async {
    final rows = await _database.query(
      '''SELECT * FROM conversations
         WHERE server_profile_id = ? AND id = ? LIMIT 1''',
      <Object?>[serverProfileId, id],
    );
    if (rows.isEmpty) return null;

    final messageRows = await _database.query(
      '''SELECT * FROM messages
         WHERE conversation_id = ?
         ORDER BY position ASC, created_at ASC, id ASC''',
      <Object?>[id],
    );
    final messages = <Message>[];
    for (final row in messageRows) {
      messages.add(await _messageFromRow(row));
    }

    return ConversationThread(
      conversation: _conversationFromRow(rows.single),
      messages: List<Message>.unmodifiable(messages),
    );
  }

  Future<List<Conversation>> listConversations(String serverProfileId) async {
    final rows = await _database.query(
      '''SELECT * FROM conversations
         WHERE server_profile_id = ?
         ORDER BY updated_at DESC, created_at DESC, id ASC''',
      <Object?>[serverProfileId],
    );
    return List<Conversation>.unmodifiable(rows.map(_conversationFromRow));
  }

  Future<bool> hasConversations(String serverProfileId) async {
    final rows = await _database.query(
      '''SELECT 1 FROM conversations
         WHERE server_profile_id = ? LIMIT 1''',
      <Object?>[serverProfileId],
    );
    return rows.isNotEmpty;
  }

  Future<bool> isImageReferenceInUse(String reference) =>
      isAttachmentReferenceInUse(reference);

  Future<bool> isAttachmentReferenceInUse(String reference) async {
    final encodedReference = _referenceCodec.encode(reference);
    final rows = await _database.query(
      'SELECT 1 FROM message_images WHERE reference = ? LIMIT 1',
      <Object?>[encodedReference],
    );
    if (rows.isNotEmpty) return true;

    final legacyImageRows = await _database.query(
      'SELECT reference FROM message_images',
    );
    for (final row in legacyImageRows) {
      final stored = row['reference'];
      if (stored is! String) {
        throw const FormatException('image reference must be text');
      }
      if (_referenceCodec.decode(stored) == reference) return true;
    }

    final documentRows = await _database.query(
      "SELECT documents_json FROM messages WHERE documents_json != '[]'",
    );
    for (final row in documentRows) {
      if (_decodeDocuments(row['documents_json'])
          .any((document) => document.reference == reference)) {
        return true;
      }
    }

    final queuedRows = await _database.query(
      '''SELECT images_json, documents_json FROM queued_prompts
         WHERE images_json != '[]' OR documents_json != '[]' ''',
    );
    for (final row in queuedRows) {
      if (_decodeImageReferences(row['images_json']).contains(reference) ||
          _decodeDocuments(row['documents_json'])
              .any((document) => document.reference == reference)) {
        return true;
      }
    }

    final checkpointRows = await _database.query(
      'SELECT messages_json FROM recovery_checkpoints',
    );
    for (final row in checkpointRows) {
      if (_referencesInMessages(_decodeCheckpointMessages(row['messages_json']))
          .contains(reference)) {
        return true;
      }
    }
    return false;
  }

  /// Conversation IDs that currently retain a recovery checkpoint.
  Future<Set<String>> recoveryCheckpointConversationIds() async {
    final rows = await _database.query(
      'SELECT conversation_id FROM recovery_checkpoints',
    );
    return {for (final row in rows) row['conversation_id']! as String};
  }

  /// Attachment references retained by [conversationId]'s checkpoint. Callers
  /// still check [isAttachmentReferenceInUse] before deleting a file.
  Future<List<String>> recoveryCheckpointReferences(
    String conversationId,
  ) async {
    final rows = await _database.query(
      '''SELECT messages_json FROM recovery_checkpoints
         WHERE conversation_id = ? LIMIT 1''',
      <Object?>[conversationId],
    );
    if (rows.isEmpty) return const <String>[];
    return _referencesInMessages(
      _decodeCheckpointMessages(rows.single['messages_json']),
    ).toList(growable: false);
  }

  /// Atomically replaces the revision tail with the checkpoint and consumes
  /// it. Returns attachment references from the discarded revision tail, which
  /// the caller may delete once they are no longer in use.
  Future<List<String>> restoreRecoveryCheckpoint(
    String conversationId,
  ) => _database.transaction((database) async {
    final rows = await database.query(
      '''SELECT from_position, messages_json FROM recovery_checkpoints
             WHERE conversation_id = ? LIMIT 1''',
      <Object?>[conversationId],
    );
    if (rows.isEmpty) {
      throw StateError('No previous conversation is available to restore.');
    }
    final fromPosition = _readInt(rows.single['from_position']);
    final restored = _decodeCheckpointMessages(rows.single['messages_json']);
    final conversationRows = await database.query(
      'SELECT is_renamed FROM conversations WHERE id = ? LIMIT 1',
      <Object?>[conversationId],
    );
    if (conversationRows.isEmpty) {
      throw StateError('Conversation $conversationId does not exist.');
    }
    final removed = await _loadTail(database, conversationId, fromPosition);
    await database.execute(
      'DELETE FROM messages WHERE conversation_id = ? AND position >= ?',
      <Object?>[conversationId, fromPosition],
    );
    for (final message in restored) {
      _validateMessage(message);
      await _insertMessage(database, message);
      await _replaceMessageParts(database, message);
    }
    await database.execute(
      'DELETE FROM recovery_checkpoints WHERE conversation_id = ?',
      <Object?>[conversationId],
    );
    await _updateTitleAfterTailChange(
      database,
      conversationId,
      explicitlyRenamed: _readInt(conversationRows.single['is_renamed']) == 1,
    );
    return _referencesInMessages(removed).toList(growable: false);
  });

  Future<List<Conversation>> listAllConversations({
    bool includeEmpty = false,
  }) async {
    final visibility = includeEmpty
        ? '1'
        : '''EXISTS (
            SELECT 1 FROM messages WHERE conversation_id = conversations.id
          ) OR EXISTS (
            SELECT 1 FROM queued_prompts
            WHERE conversation_id = conversations.id
          )''';
    final rows = await _database.query('''SELECT * FROM conversations
        WHERE $visibility
        ORDER BY updated_at DESC, created_at DESC, id ASC''');
    return rows.map(_conversationFromRow).toList(growable: false);
  }

  Future<List<ConversationSearchResult>> search(String query) async {
    final term = query.trim();
    if (term.isEmpty) return const [];
    final rows = await _database.query('''SELECT c.*,
        (SELECT content FROM messages m WHERE m.conversation_id = c.id
          AND m.role IN ('user', 'assistant')
          AND instr(lower(m.content), lower(?)) > 0
          ORDER BY m.position LIMIT 1) AS matching_content
        FROM conversations c
        WHERE instr(lower(c.title), lower(?)) > 0
          OR EXISTS (SELECT 1 FROM messages m WHERE m.conversation_id = c.id
            AND m.role IN ('user', 'assistant')
            AND instr(lower(m.content), lower(?)) > 0)
        ORDER BY CASE WHEN lower(c.title) = lower(?) THEN 0
          WHEN instr(lower(c.title), lower(?)) = 1 THEN 1
          WHEN instr(lower(c.title), lower(?)) > 0 THEN 2 ELSE 3 END,
          c.updated_at DESC, c.id ASC''', List<Object?>.filled(6, term));
    return rows
        .map((row) {
          final content = row['matching_content'] as String?;
          String? excerpt;
          if (content != null) {
            final match = content.toLowerCase().indexOf(term.toLowerCase());
            final start = (match - 40).clamp(0, content.length);
            final end = (start + 180).clamp(start, content.length);
            excerpt =
                '${start > 0 ? '…' : ''}${content.substring(start, end).replaceAll(RegExp(r'\s+'), ' ')}${end < content.length ? '…' : ''}';
          }
          return ConversationSearchResult(_conversationFromRow(row), excerpt);
        })
        .toList(growable: false);
  }

  Future<void> rename(String id, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) throw const FormatException('Enter a chat name.');
    await _database.execute(
      '''UPDATE conversations SET title = ?,
        is_renamed = 1, title_from_first_user = 1 WHERE id = ?''',
      [trimmed, id],
    );
  }

  Future<void> setPinned(String id, bool value) => _database.execute(
    'UPDATE conversations SET is_pinned = ? WHERE id = ?',
    [value ? 1 : 0, id],
  );

  Future<void> setArchived(String id, bool value) => _database.execute(
    'UPDATE conversations SET is_archived = ? WHERE id = ?',
    [value ? 1 : 0, id],
  );

  Future<void> deleteAllConversations() =>
      _database.transaction((database) async {
        await database.execute('DELETE FROM conversations');
        await database.execute('DELETE FROM chat_drafts');
      });

  Future<bool> hasSyncReceipt(String token) async {
    _validateReceiptToken(token);
    final rows = await _database.query(
      'SELECT 1 FROM sync_receipts WHERE token = ? LIMIT 1',
      <Object?>[token],
    );
    return rows.isNotEmpty;
  }

  Future<void> applySyncDeletion({
    required String conversationId,
    required String receiptToken,
  }) async {
    if (conversationId.trim().isEmpty) {
      throw ArgumentError.value(
        conversationId,
        'conversationId',
        'must not be empty',
      );
    }
    _validateReceiptToken(receiptToken);
    await _database.transaction((database) async {
      if (await _hasSyncReceipt(database, receiptToken)) return;
      await database.execute(
        'DELETE FROM conversations WHERE id = ?',
        <Object?>[conversationId],
      );
      await database.execute(
        'DELETE FROM chat_drafts WHERE scope = ?',
        <Object?>[conversationId],
      );
      await _insertSyncReceipt(database, receiptToken);
    });
  }

  Future<Map<String, Map<String, Object?>>> loadDrafts() async {
    final rows = await _database.query(
      'SELECT scope, data_json FROM chat_drafts ORDER BY scope ASC',
    );
    final drafts = <String, Map<String, Object?>>{};
    for (final row in rows) {
      final scope = row['scope'];
      final rawData = row['data_json'];
      if (scope is! String || scope.trim().isEmpty) {
        throw const FormatException('draft scope must not be empty');
      }
      if (rawData is! String) {
        throw FormatException('draft $scope must be JSON text');
      }
      final decoded = jsonDecode(rawData);
      if (decoded is! Map) {
        throw FormatException('draft $scope must be a JSON object');
      }
      drafts[scope] = _decodeDraft(Map<String, Object?>.from(decoded));
    }
    return Map<String, Map<String, Object?>>.unmodifiable(drafts);
  }

  Future<void> saveDrafts(Map<String, Map<String, Object?>> drafts) async {
    final encoded = <String, String>{};
    for (final entry in drafts.entries) {
      if (entry.key.trim().isEmpty) {
        throw const FormatException('draft scope must not be empty');
      }
      encoded[entry.key] = jsonEncode(_encodeDraft(entry.value));
    }

    await _database.transaction((database) async {
      await database.execute('DELETE FROM chat_drafts');
      for (final entry in encoded.entries) {
        await database.execute(
          'INSERT INTO chat_drafts(scope, data_json) VALUES(?, ?)',
          <Object?>[entry.key, entry.value],
        );
      }
    });
  }

  Future<List<QueuedPrompt>> loadQueuedPrompts({String? conversationId}) async {
    if (conversationId != null) {
      _validateQueuedPromptId(conversationId, 'conversationId');
    }
    final rows = await _database.query(
      conversationId == null
          ? '''SELECT * FROM queued_prompts
             ORDER BY conversation_id ASC, position ASC, created_at ASC, id ASC'''
          : '''SELECT * FROM queued_prompts WHERE conversation_id = ?
             ORDER BY position ASC, created_at ASC, id ASC''',
      conversationId == null ? const <Object?>[] : <Object?>[conversationId],
    );
    return List<QueuedPrompt>.unmodifiable(rows.map(_queuedPromptFromRow));
  }

  Future<QueuedPrompt> enqueuePrompt(QueuedPrompt prompt) async {
    _validateQueuedPrompt(prompt);
    final normalized = QueuedPrompt(
      id: prompt.id,
      conversationId: prompt.conversationId,
      text: prompt.text,
      imageReferences: prompt.imageReferences,
      documents: prompt.documents,
      createdAt: prompt.createdAt.toUtc(),
    );
    return _database.transaction((database) async {
      await _requireConversation(database, normalized.conversationId);
      final duplicate = await database.query(
        'SELECT conversation_id FROM queued_prompts WHERE id = ? LIMIT 1',
        <Object?>[normalized.id],
      );
      if (duplicate.isNotEmpty) {
        throw FormatException(
          'Queued prompt ID ${normalized.id} already exists.',
        );
      }
      final positionRows = await database.query(
        '''SELECT COALESCE(MAX(position), -1) + 1 AS next_position
           FROM queued_prompts WHERE conversation_id = ?''',
        <Object?>[normalized.conversationId],
      );
      final position = positionRows.isEmpty
          ? 0
          : _readInt(positionRows.single['next_position']);
      await _insertQueuedPrompt(database, normalized, position);
      await database.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        <Object?>[_toEpoch(normalized.createdAt), normalized.conversationId],
      );
      return normalized;
    });
  }

  Future<void> updateQueuedPromptText({
    required String conversationId,
    required String id,
    required String text,
  }) async {
    _validateQueuedPromptId(conversationId, 'conversationId');
    _validateQueuedPromptId(id, 'id');
    await _database.transaction((database) async {
      final stored = await _loadQueuedPromptById(database, id);
      if (stored == null) {
        throw FormatException('Queued prompt $id does not exist.');
      }
      final prompt = stored.prompt;
      if (prompt.conversationId != conversationId) {
        throw FormatException(
          'Queued prompt $id belongs to a different conversation.',
        );
      }
      final updated = prompt.copyWith(text: text);
      _validateQueuedPrompt(updated);
      await database.execute(
        '''UPDATE queued_prompts SET text = ?
           WHERE conversation_id = ? AND id = ?''',
        <Object?>[text, conversationId, id],
      );
      await database.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        <Object?>[_toEpoch(DateTime.now().toUtc()), conversationId],
      );
    });
  }

  Future<void> deleteQueuedPrompt({
    required String conversationId,
    required String id,
  }) async {
    _validateQueuedPromptId(conversationId, 'conversationId');
    _validateQueuedPromptId(id, 'id');
    await _database.transaction((database) async {
      final stored = await _loadQueuedPromptById(database, id);
      if (stored == null) {
        throw FormatException('Queued prompt $id does not exist.');
      }
      if (stored.prompt.conversationId != conversationId) {
        throw FormatException(
          'Queued prompt $id belongs to a different conversation.',
        );
      }
      await database.execute(
        'DELETE FROM queued_prompts WHERE conversation_id = ? AND id = ?',
        <Object?>[conversationId, id],
      );
      await database.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        <Object?>[_toEpoch(DateTime.now().toUtc()), conversationId],
      );
    });
  }

  Future<void> reorderQueuedPrompts({
    required String conversationId,
    required List<String> ids,
  }) async {
    _validateQueuedPromptId(conversationId, 'conversationId');
    final requested = <String>{};
    for (final id in ids) {
      _validateQueuedPromptId(id, 'id');
      if (!requested.add(id)) {
        throw const FormatException(
          'Queued prompt reorder IDs must be unique.',
        );
      }
    }
    await _database.transaction((database) async {
      await _requireConversation(database, conversationId);
      final rows = await database.query(
        '''SELECT id, position FROM queued_prompts
           WHERE conversation_id = ? ORDER BY position ASC''',
        <Object?>[conversationId],
      );
      final storedIds = rows.map((row) => row['id']! as String).toSet();
      if (storedIds.length != ids.length || !storedIds.containsAll(requested)) {
        throw const FormatException(
          'Queued prompt reorder must contain every queued prompt exactly once.',
        );
      }
      if (ids.isEmpty) return;
      final maximum = rows
          .map((row) => _readInt(row['position']))
          .reduce((left, right) => left > right ? left : right);
      final offset = maximum + ids.length + 1;
      await database.execute(
        '''UPDATE queued_prompts SET position = position + ?
           WHERE conversation_id = ?''',
        <Object?>[offset, conversationId],
      );
      for (var position = 0; position < ids.length; position++) {
        await database.execute(
          '''UPDATE queued_prompts SET position = ?
             WHERE conversation_id = ? AND id = ?''',
          <Object?>[position, conversationId, ids[position]],
        );
      }
      await database.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        <Object?>[_toEpoch(DateTime.now().toUtc()), conversationId],
      );
    });
  }

  /// Claims the oldest queued prompt before transport dispatch.
  ///
  /// This follows Jaz's Apache-2.0 queue claim pattern at revision b9b3a0a7,
  /// rewritten around MobileLlama's local SQLite message schema. Persisting the
  /// user turn and response placeholder in the same transaction ensures a
  /// restart cannot lose a prompt between queue removal and request startup.
  Future<QueuedPromptClaim?> claimQueuedPrompt(
    String conversationId, {
    required String userMessageId,
    required String assistantMessageId,
    DateTime? now,
  }) async {
    _validateQueuedPromptId(conversationId, 'conversationId');
    _validateQueuedPromptId(userMessageId, 'userMessageId');
    _validateQueuedPromptId(assistantMessageId, 'assistantMessageId');
    if (userMessageId == assistantMessageId) {
      throw const FormatException('Claimed message IDs must be distinct.');
    }
    return _database.transaction((database) async {
      await _requireConversation(database, conversationId);
      final running = await database.query(
        '''SELECT 1 FROM messages WHERE conversation_id = ?
           AND role = 'assistant' AND status = 'streaming' LIMIT 1''',
        <Object?>[conversationId],
      );
      if (running.isNotEmpty) {
        throw const FormatException(
          'Cannot claim a queued prompt while a response is streaming.',
        );
      }
      final rows = await database.query(
        '''SELECT * FROM queued_prompts WHERE conversation_id = ?
           ORDER BY position ASC, created_at ASC, id ASC LIMIT 1''',
        <Object?>[conversationId],
      );
      if (rows.isEmpty) return null;
      final prompt = _queuedPromptFromRow(rows.single);
      final originalPosition = _readInt(rows.single['position']);
      final collisions = await database.query(
        'SELECT id FROM messages WHERE id IN (?, ?)',
        <Object?>[userMessageId, assistantMessageId],
      );
      if (collisions.isNotEmpty) {
        throw const FormatException('Claimed message ID already exists.');
      }
      final nextRows = await database.query(
        '''SELECT COALESCE(MAX(position), -1) + 1 AS next_position
           FROM messages WHERE conversation_id = ?''',
        <Object?>[conversationId],
      );
      final userPosition = nextRows.isEmpty
          ? 0
          : _readInt(nextRows.single['next_position']);
      final timestamp = (now ?? DateTime.now()).toUtc();
      final user = Message(
        id: userMessageId,
        conversationId: conversationId,
        position: userPosition,
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: prompt.text,
        imageReferences: prompt.imageReferences,
        documents: prompt.documents,
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      final assistant = Message(
        id: assistantMessageId,
        conversationId: conversationId,
        position: userPosition + 1,
        role: MessageRole.assistant,
        status: MessageStatus.streaming,
        content: '',
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      _validateMessage(user);
      _validateMessage(assistant);
      await _insertMessage(database, user);
      await _replaceMessageParts(database, user);
      await _insertMessage(database, assistant);
      await _replaceMessageParts(database, assistant);
      await database.execute(
        '''UPDATE conversations
           SET title = ?, title_from_first_user = 1, updated_at = ?
           WHERE id = ? AND title_from_first_user = 0''',
        <Object?>[
          titleFromFirstUserText(prompt.text),
          _toEpoch(timestamp),
          conversationId,
        ],
      );
      await database.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        <Object?>[_toEpoch(timestamp), conversationId],
      );
      await database.execute(
        '''DELETE FROM queued_prompts
           WHERE conversation_id = ? AND id = ? AND position = ?''',
        <Object?>[conversationId, prompt.id, originalPosition],
      );
      // A committed new user turn ends the previous revision's recovery.
      await database.execute(
        'DELETE FROM recovery_checkpoints WHERE conversation_id = ?',
        <Object?>[conversationId],
      );
      return QueuedPromptClaim(
        prompt: prompt,
        userMessage: user,
        assistantMessage: assistant,
        originalPosition: originalPosition,
      );
    });
  }

  Future<void> restoreQueuedPrompt(QueuedPromptClaim claim) async {
    _validateQueuedPrompt(claim.prompt);
    if (claim.originalPosition < 0) {
      throw const FormatException(
        'Queued prompt claim position must not be negative.',
      );
    }
    final conversationId = claim.prompt.conversationId;
    if (claim.userMessage.conversationId != conversationId ||
        claim.assistantMessage.conversationId != conversationId ||
        claim.userMessage.role != MessageRole.user ||
        claim.assistantMessage.role != MessageRole.assistant ||
        claim.assistantMessage.position != claim.userMessage.position + 1) {
      throw const FormatException('Queued prompt claim is inconsistent.');
    }
    await _database.transaction((database) async {
      final conversationRows = await database.query(
        'SELECT is_renamed FROM conversations WHERE id = ? LIMIT 1',
        <Object?>[conversationId],
      );
      if (conversationRows.isEmpty) {
        throw FormatException('Conversation $conversationId does not exist.');
      }
      final tailRows = await database.query(
        '''SELECT * FROM messages WHERE conversation_id = ? AND position >= ?
           ORDER BY position ASC, created_at ASC, id ASC''',
        <Object?>[conversationId, claim.userMessage.position],
      );
      if (tailRows.length != 2) {
        throw const FormatException(
          'Claimed prompt is no longer the untouched conversation tail.',
        );
      }
      final storedUser = await _messageFromDatabase(database, tailRows[0]);
      final storedAssistant = await _messageFromDatabase(database, tailRows[1]);
      if (!_storedTailMatchesClaim(claim, storedUser, storedAssistant)) {
        throw const FormatException(
          'Claimed prompt is no longer the untouched conversation tail.',
        );
      }
      final queuedRows = await database.query(
        '''SELECT * FROM queued_prompts WHERE conversation_id = ?
           ORDER BY position ASC, created_at ASC, id ASC''',
        <Object?>[conversationId],
      );
      final remaining = queuedRows.map(_queuedPromptFromRow).toList();
      if (remaining.any((prompt) => prompt.id == claim.prompt.id)) {
        throw FormatException(
          'Queued prompt ID ${claim.prompt.id} already exists.',
        );
      }

      await database.execute(
        'DELETE FROM messages WHERE conversation_id = ? AND position >= ?',
        <Object?>[conversationId, claim.userMessage.position],
      );
      await database.execute(
        'DELETE FROM queued_prompts WHERE conversation_id = ?',
        <Object?>[conversationId],
      );
      await _insertQueuedPrompt(database, claim.prompt, 0);
      for (var index = 0; index < remaining.length; index++) {
        await _insertQueuedPrompt(database, remaining[index], index + 1);
      }

      final timestamp = DateTime.now().toUtc();
      final explicitlyRenamed =
          _readInt(conversationRows.single['is_renamed']) == 1;
      if (explicitlyRenamed) {
        await database.execute(
          'UPDATE conversations SET updated_at = ? WHERE id = ?',
          <Object?>[_toEpoch(timestamp), conversationId],
        );
      } else {
        final firstUserRows = await database.query(
          '''SELECT content FROM messages
             WHERE conversation_id = ? AND role = 'user'
             ORDER BY position ASC LIMIT 1''',
          <Object?>[conversationId],
        );
        await database.execute(
          '''UPDATE conversations
             SET title = ?, title_from_first_user = ?, updated_at = ?
             WHERE id = ?''',
          <Object?>[
            firstUserRows.isEmpty
                ? 'New chat'
                : titleFromFirstUserText(
                    firstUserRows.single['content']! as String,
                  ),
            firstUserRows.isEmpty ? 0 : 1,
            _toEpoch(timestamp),
            conversationId,
          ],
        );
      }
    });
  }

  Future<void> updateConversationContext({
    required String id,
    required String selectedModel,
    required String systemPrompt,
    DateTime? now,
  }) => _database.execute(
    '''UPDATE conversations
           SET selected_model = ?, system_prompt = ?, updated_at = ?
           WHERE id = ?''',
    <Object?>[
      selectedModel,
      systemPrompt,
      _toEpoch((now ?? DateTime.now()).toUtc()),
      id,
    ],
  );

  Future<void> updateConversationGenerationOptions({
    required String id,
    required GenerationOptions generationOptions,
    DateTime? now,
  }) => _database.transaction((database) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    await database.execute(
      '''UPDATE conversations
         SET generation_options_json = ?, updated_at = ?
         WHERE id = ?''',
      <Object?>[
        jsonEncode(generationOptions.toOllamaJson()),
        _toEpoch(timestamp),
        id,
      ],
    );
  });

  Future<void> updateConversationSettings({
    required String id,
    required String selectedModel,
    required String systemPrompt,
    required GenerationOptions generationOptions,
    DateTime? now,
  }) => _database.transaction((database) async {
    final timestamp = (now ?? DateTime.now()).toUtc();
    await database.execute(
      '''UPDATE conversations
         SET selected_model = ?, system_prompt = ?,
             generation_options_json = ?, updated_at = ?
         WHERE id = ?''',
      <Object?>[
        selectedModel,
        systemPrompt,
        jsonEncode(generationOptions.toOllamaJson()),
        _toEpoch(timestamp),
        id,
      ],
    );
  });

  Future<void> deleteConversation({
    required String serverProfileId,
    required String id,
  }) => _database.transaction((database) async {
    final rows = await database.query(
      '''SELECT 1 FROM conversations
         WHERE server_profile_id = ? AND id = ? LIMIT 1''',
      <Object?>[serverProfileId, id],
    );
    if (rows.isEmpty) return;
    await database.execute(
      'DELETE FROM conversations WHERE server_profile_id = ? AND id = ?',
      <Object?>[serverProfileId, id],
    );
    await database.execute('DELETE FROM chat_drafts WHERE scope = ?', <Object?>[
      id,
    ]);
  });

  Future<Message> appendMessage({
    required String id,
    required String conversationId,
    required MessageRole role,
    required MessageStatus status,
    required String content,
    String? reasoning,
    List<String> imageReferences = const <String>[],
    List<DocumentAttachment> documents = const <DocumentAttachment>[],
    List<ToolCall> toolCalls = const <ToolCall>[],
    List<ToolResult> toolResults = const <ToolResult>[],
    DateTime? now,
  }) => _database.transaction((database) async {
    final positionRows = await database.query(
      '''SELECT COALESCE(MAX(position), -1) + 1 AS next_position
             FROM messages WHERE conversation_id = ?''',
      <Object?>[conversationId],
    );
    final position = positionRows.isEmpty
        ? 0
        : _readInt(positionRows.single['next_position']);
    final timestamp = (now ?? DateTime.now()).toUtc();
    final message = Message(
      id: id,
      conversationId: conversationId,
      position: position,
      role: role,
      status: status,
      content: content,
      reasoning: reasoning,
      imageReferences: List<String>.unmodifiable(imageReferences),
      documents: List<DocumentAttachment>.unmodifiable(documents),
      toolCalls: List<ToolCall>.unmodifiable(toolCalls),
      toolResults: List<ToolResult>.unmodifiable(toolResults),
      createdAt: timestamp,
      updatedAt: timestamp,
    );
    _validateMessage(message);

    await _insertMessage(database, message);
    await _replaceMessageParts(database, message);
    await database.execute(
      'UPDATE conversations SET updated_at = ? WHERE id = ?',
      <Object?>[_toEpoch(timestamp), conversationId],
    );

    if (role == MessageRole.user) {
      await database.execute(
        '''UPDATE conversations
               SET title = ?, title_from_first_user = 1, updated_at = ?
               WHERE id = ? AND title_from_first_user = 0''',
        <Object?>[
          titleFromFirstUserText(content),
          _toEpoch(timestamp),
          conversationId,
        ],
      );
      await database.execute(
        'DELETE FROM recovery_checkpoints WHERE conversation_id = ?',
        <Object?>[conversationId],
      );
    }
    return message;
  });

  /// Replaces messages from [fromPosition]. With [saveRecoveryCheckpoint],
  /// the removed tail becomes the chat's single recovery checkpoint in the
  /// same transaction, replacing any earlier checkpoint.
  ///
  /// Returns attachment references that the replacement may have released
  /// (from the removed tail and any replaced checkpoint). Callers must still
  /// check [isAttachmentReferenceInUse] before deleting a file.
  Future<List<String>> replaceConversationTail({
    required String conversationId,
    required int fromPosition,
    Message? replacement,
    bool saveRecoveryCheckpoint = false,
  }) async {
    if (conversationId.trim().isEmpty) {
      throw ArgumentError.value(
        conversationId,
        'conversationId',
        'must not be empty',
      );
    }
    if (fromPosition < 0) {
      throw RangeError.range(fromPosition, 0, null, 'fromPosition');
    }
    if (replacement != null) {
      if (replacement.conversationId != conversationId) {
        throw ArgumentError.value(
          replacement.conversationId,
          'replacement.conversationId',
          'must match conversationId',
        );
      }
      if (replacement.position != fromPosition) {
        throw ArgumentError.value(
          replacement.position,
          'replacement.position',
          'must match fromPosition',
        );
      }
      _validateMessage(replacement);
    }

    return _database.transaction((database) async {
      final conversationRows = await database.query(
        'SELECT is_renamed FROM conversations WHERE id = ? LIMIT 1',
        <Object?>[conversationId],
      );
      if (conversationRows.isEmpty) {
        throw ArgumentError.value(
          conversationId,
          'conversationId',
          'unknown conversation',
        );
      }

      final targetRows = await database.query(
        '''SELECT id FROM messages
           WHERE conversation_id = ? AND position = ? LIMIT 1''',
        <Object?>[conversationId, fromPosition],
      );
      if (targetRows.isEmpty) {
        throw RangeError.value(
          fromPosition,
          'fromPosition',
          'does not identify a stored message',
        );
      }

      if (replacement != null) {
        await _rejectReplacementIdentityCollisions(
          database,
          conversationId: conversationId,
          fromPosition: fromPosition,
          replacement: replacement,
        );
      }

      final removed = await _loadTail(database, conversationId, fromPosition);
      final released = <String>{..._referencesInMessages(removed)};
      if (saveRecoveryCheckpoint) {
        final previous = await database.query(
          '''SELECT messages_json FROM recovery_checkpoints
             WHERE conversation_id = ? LIMIT 1''',
          <Object?>[conversationId],
        );
        for (final row in previous) {
          released.addAll(
            _referencesInMessages(
              _decodeCheckpointMessages(row['messages_json']),
            ),
          );
        }
        await database.execute(
          '''INSERT OR REPLACE INTO recovery_checkpoints(
               conversation_id, from_position, messages_json, created_at
             ) VALUES(?, ?, ?, ?)''',
          <Object?>[
            conversationId,
            fromPosition,
            jsonEncode(removed.map(_encodeCheckpointMessage).toList()),
            _toEpoch(DateTime.now().toUtc()),
          ],
        );
      }
      await database.execute(
        'DELETE FROM messages WHERE conversation_id = ? AND position >= ?',
        <Object?>[conversationId, fromPosition],
      );
      if (replacement != null) {
        await _insertMessage(database, replacement);
        await _replaceMessageParts(database, replacement);
      }

      await _updateTitleAfterTailChange(
        database,
        conversationId,
        explicitlyRenamed: _readInt(conversationRows.single['is_renamed']) == 1,
      );
      return released.toList(growable: false);
    });
  }

  Future<List<Message>> _loadTail(
    SqliteDatabase database,
    String conversationId,
    int fromPosition,
  ) async {
    final rows = await database.query(
      '''SELECT * FROM messages WHERE conversation_id = ? AND position >= ?
         ORDER BY position ASC, created_at ASC, id ASC''',
      <Object?>[conversationId, fromPosition],
    );
    return [for (final row in rows) await _messageFromDatabase(database, row)];
  }

  static Set<String> _referencesInMessages(Iterable<Message> messages) => {
    for (final message in messages) ...[
      ...message.imageReferences,
      ...message.documents.map((document) => document.reference),
    ],
  };

  /// Recomputes an automatically derived title from the first user turn and
  /// preserves an explicit name.
  Future<void> _updateTitleAfterTailChange(
    SqliteDatabase database,
    String conversationId, {
    required bool explicitlyRenamed,
  }) async {
    final timestamp = DateTime.now().toUtc();
    if (explicitlyRenamed) {
      await database.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        <Object?>[_toEpoch(timestamp), conversationId],
      );
      return;
    }
    final firstUserRows = await database.query(
      '''SELECT content FROM messages
         WHERE conversation_id = ? AND role = 'user'
         ORDER BY position ASC LIMIT 1''',
      <Object?>[conversationId],
    );
    final hasUserMessage = firstUserRows.isNotEmpty;
    final title = hasUserMessage
        ? titleFromFirstUserText(firstUserRows.single['content']! as String)
        : 'New chat';
    await database.execute(
      '''UPDATE conversations
         SET title = ?, title_from_first_user = ?, updated_at = ?
         WHERE id = ?''',
      <Object?>[
        title,
        hasUserMessage ? 1 : 0,
        _toEpoch(timestamp),
        conversationId,
      ],
    );
  }

  Map<String, Object?> _encodeCheckpointMessage(Message message) => {
    'id': message.id,
    'conversationId': message.conversationId,
    'position': message.position,
    'role': message.role.name,
    'status': message.status.name,
    'content': message.content,
    'reasoning': message.reasoning,
    'providerTranscriptJson': message.providerTranscriptJson,
    'images': message.imageReferences.map(_referenceCodec.encode).toList(),
    'documents': jsonDecode(_encodeDocuments(message.documents)),
    'toolCalls': message.toolCalls.map((call) => call.toJson()).toList(),
    'toolResults': message.toolResults
        .map((result) => result.toJson())
        .toList(),
    'createdAt': _toEpoch(message.createdAt),
    'updatedAt': _toEpoch(message.updatedAt),
  };

  List<Message> _decodeCheckpointMessages(Object? value) {
    if (value is! String) {
      throw const FormatException('recovery checkpoint must be JSON text');
    }
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      throw const FormatException('recovery checkpoint must be a JSON array');
    }
    return [
      for (final entry in decoded)
        if (entry is Map)
          _decodeCheckpointMessage(Map<String, Object?>.from(entry))
        else
          throw const FormatException('checkpoint message must be an object'),
    ];
  }

  Message _decodeCheckpointMessage(Map<String, Object?> json) => Message(
    id: json['id']! as String,
    conversationId: json['conversationId']! as String,
    position: _readInt(json['position']),
    role: _enumByName(MessageRole.values, json['role']! as String),
    status: _enumByName(MessageStatus.values, json['status']! as String),
    content: json['content']! as String,
    reasoning: json['reasoning'] as String?,
    providerTranscriptJson: json['providerTranscriptJson'] as String?,
    imageReferences: List<String>.unmodifiable([
      for (final reference in json['images']! as List)
        _referenceCodec.decode(reference as String),
    ]),
    documents: List<DocumentAttachment>.unmodifiable(
      _decodeDocuments(jsonEncode(json['documents'])),
    ),
    toolCalls: List<ToolCall>.unmodifiable([
      for (final call in json['toolCalls']! as List)
        ToolCall.fromJson(Map<String, Object?>.from(call as Map)),
    ]),
    toolResults: List<ToolResult>.unmodifiable([
      for (final result in json['toolResults']! as List)
        ToolResult.fromJson(Map<String, Object?>.from(result as Map)),
    ]),
    createdAt: _fromEpoch(json['createdAt']),
    updatedAt: _fromEpoch(json['updatedAt']),
  );

  Future<void> importThreadsAtomically(List<ConversationThread> threads) async {
    _validateImportedThreads(threads);
    await _database.transaction((database) async {
      for (final thread in threads) {
        await _insertThread(database, thread);
      }
    });
  }

  Future<bool> applySyncedThreadAtomically(
    ConversationThread thread, {
    required String receiptToken,
    required bool replaceExisting,
  }) async {
    _validateImportedThreads(<ConversationThread>[thread]);
    _validateReceiptToken(receiptToken);
    return _database.transaction((database) async {
      if (await _hasSyncReceipt(database, receiptToken)) return false;
      await _rejectSyncedIdentityCollisions(
        database,
        thread: thread,
        allowConversationId: replaceExisting ? thread.conversation.id : null,
      );
      if (replaceExisting) {
        await database.execute(
          'DELETE FROM conversations WHERE id = ?',
          <Object?>[thread.conversation.id],
        );
      }
      await _insertThread(database, thread);
      await _insertSyncReceipt(database, receiptToken);
      return true;
    });
  }

  Future<void> updateMessage(Message message) async {
    _validateMessage(message);
    await _database.transaction((database) async {
      await database.execute(
        '''UPDATE messages
             SET status = ?, content = ?, reasoning = ?,
                 provider_transcript_json = ?, documents_json = ?,
                 updated_at = ?
             WHERE id = ? AND conversation_id = ?''',
        <Object?>[
          message.status.name,
          message.content,
          message.reasoning,
          message.providerTranscriptJson,
          _encodeDocuments(message.documents),
          _toEpoch(message.updatedAt),
          message.id,
          message.conversationId,
        ],
      );
      await _replaceMessageParts(database, message);
      await database.execute(
        'UPDATE conversations SET updated_at = ? WHERE id = ?',
        <Object?>[_toEpoch(message.updatedAt), message.conversationId],
      );
    });
  }

  Future<void> deleteMessage(String id) =>
      _database.execute('DELETE FROM messages WHERE id = ?', <Object?>[id]);

  Future<Message> _messageFromRow(Map<String, Object?> row) =>
      _messageFromDatabase(_database, row);

  Future<Message> _messageFromDatabase(
    SqliteDatabase database,
    Map<String, Object?> row,
  ) async {
    final id = row['id']! as String;
    final imageRows = await database.query(
      '''SELECT reference FROM message_images
         WHERE message_id = ? ORDER BY position ASC, reference ASC''',
      <Object?>[id],
    );
    final callRows = await database.query(
      '''SELECT * FROM tool_calls
         WHERE message_id = ? ORDER BY position ASC, id ASC''',
      <Object?>[id],
    );
    final resultRows = await database.query(
      '''SELECT * FROM tool_results
         WHERE message_id = ? ORDER BY position ASC, id ASC''',
      <Object?>[id],
    );

    return Message(
      id: id,
      conversationId: row['conversation_id']! as String,
      position: _readInt(row['position']),
      role: _enumByName(MessageRole.values, row['role']! as String),
      status: _enumByName(MessageStatus.values, row['status']! as String),
      content: row['content']! as String,
      reasoning: row['reasoning'] as String?,
      providerTranscriptJson: row['provider_transcript_json'] as String?,
      imageReferences: List<String>.unmodifiable(
        imageRows.map(
          (image) => _referenceCodec.decode(image['reference']! as String),
        ),
      ),
      documents: List<DocumentAttachment>.unmodifiable(
        _decodeDocuments(row['documents_json']),
      ),
      toolCalls: List<ToolCall>.unmodifiable(
        callRows.map((call) {
          return ToolCall(
            id: call['id']! as String,
            name: call['name']! as String,
            arguments: _decodeToolArguments(call['arguments_json']),
          );
        }),
      ),
      toolResults: List<ToolResult>.unmodifiable(
        resultRows.map((result) {
          return ToolResult(
            id: result['id']! as String,
            toolCallId: result['tool_call_id']! as String,
            content: result['content']! as String,
            isError: _readInt(result['is_error']) == 1,
          );
        }),
      ),
      createdAt: _fromEpoch(row['created_at']),
      updatedAt: _fromEpoch(row['updated_at']),
    );
  }

  static Conversation _conversationFromRow(Map<String, Object?> row) =>
      Conversation(
        id: row['id']! as String,
        serverProfileId: row['server_profile_id']! as String,
        title: row['title']! as String,
        isPinned: row['is_pinned'] == 1,
        isArchived: row['is_archived'] == 1,
        isRenamed: row['is_renamed'] == 1,
        selectedModel: row['selected_model']! as String,
        systemPrompt: row['system_prompt']! as String,
        generationOptions: _decodeGenerationOptions(
          row['generation_options_json'],
        ),
        createdAt: _fromEpoch(row['created_at']),
        updatedAt: _fromEpoch(row['updated_at']),
      );

  QueuedPrompt _queuedPromptFromRow(Map<String, Object?> row) => QueuedPrompt(
    id: row['id']! as String,
    conversationId: row['conversation_id']! as String,
    text: row['text']! as String,
    imageReferences: _decodeImageReferences(row['images_json']),
    documents: _decodeDocuments(row['documents_json']),
    createdAt: _fromEpoch(row['created_at']),
  );

  Future<({QueuedPrompt prompt, int position})?> _loadQueuedPromptById(
    SqliteDatabase database,
    String id,
  ) async {
    final rows = await database.query(
      'SELECT * FROM queued_prompts WHERE id = ? LIMIT 1',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return (
      prompt: _queuedPromptFromRow(rows.single),
      position: _readInt(rows.single['position']),
    );
  }

  Future<void> _insertQueuedPrompt(
    SqliteDatabase database,
    QueuedPrompt prompt,
    int position,
  ) {
    if (position < 0) {
      throw const FormatException(
        'Queued prompt position must not be negative.',
      );
    }
    final imagesJson = _encodeImageReferences(prompt.imageReferences);
    final documentsJson = _encodeDocuments(prompt.documents);
    return database.execute(
      '''INSERT INTO queued_prompts(
           id, conversation_id, position, text, images_json,
           documents_json, created_at
         ) VALUES(?, ?, ?, ?, ?, ?, ?)''',
      <Object?>[
        prompt.id,
        prompt.conversationId,
        position,
        prompt.text,
        imagesJson,
        documentsJson,
        _toEpoch(prompt.createdAt),
      ],
    );
  }

  static Future<void> _requireConversation(
    SqliteDatabase database,
    String conversationId,
  ) async {
    final rows = await database.query(
      'SELECT 1 FROM conversations WHERE id = ? LIMIT 1',
      <Object?>[conversationId],
    );
    if (rows.isEmpty) {
      throw FormatException('Conversation $conversationId does not exist.');
    }
  }

  static bool _storedTailMatchesClaim(
    QueuedPromptClaim claim,
    Message user,
    Message assistant,
  ) {
    final prompt = claim.prompt;
    final userMatches =
        user.id == claim.userMessage.id &&
        user.position == claim.userMessage.position &&
        user.role == MessageRole.user &&
        user.status == MessageStatus.complete &&
        user.content == prompt.text &&
        _sameStrings(user.imageReferences, prompt.imageReferences) &&
        _sameDocuments(user.documents, prompt.documents) &&
        user.reasoning == null &&
        user.providerTranscriptJson == null &&
        user.toolCalls.isEmpty &&
        user.toolResults.isEmpty;
    final restorableAssistantStatus =
        assistant.status == MessageStatus.streaming ||
        assistant.status == MessageStatus.interrupted ||
        assistant.status == MessageStatus.failed ||
        assistant.status == MessageStatus.partial;
    final assistantMatches =
        assistant.id == claim.assistantMessage.id &&
        assistant.position == claim.assistantMessage.position &&
        assistant.role == MessageRole.assistant &&
        restorableAssistantStatus &&
        assistant.content.isEmpty &&
        (assistant.reasoning == null || assistant.reasoning!.isEmpty) &&
        assistant.providerTranscriptJson == null &&
        assistant.imageReferences.isEmpty &&
        assistant.documents.isEmpty &&
        assistant.toolCalls.isEmpty &&
        assistant.toolResults.isEmpty;
    return userMatches && assistantMatches;
  }

  static bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _sameDocuments(
    List<DocumentAttachment> left,
    List<DocumentAttachment> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final first = left[index];
      final second = right[index];
      if (first.id != second.id ||
          first.name != second.name ||
          first.mimeType != second.mimeType ||
          first.reference != second.reference ||
          first.text != second.text) {
        return false;
      }
    }
    return true;
  }

  Future<void> _insertMessage(SqliteDatabase database, Message message) =>
      database.execute(
        '''INSERT INTO messages(
             id, conversation_id, position, role, status, content, reasoning,
             provider_transcript_json, documents_json, created_at, updated_at
           ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
        <Object?>[
          message.id,
          message.conversationId,
          message.position,
          message.role.name,
          message.status.name,
          message.content,
          message.reasoning,
          message.providerTranscriptJson,
          _encodeDocuments(message.documents),
          _toEpoch(message.createdAt),
          _toEpoch(message.updatedAt),
        ],
      );

  Future<void> _insertThread(
    SqliteDatabase database,
    ConversationThread thread,
  ) async {
    final conversation = thread.conversation;
    final hasUserMessage = thread.messages.any(
      (message) => message.role == MessageRole.user,
    );
    await database.execute(
      '''INSERT INTO conversations(
           id, server_profile_id, title, title_from_first_user,
           selected_model, system_prompt, generation_options_json,
           created_at, updated_at, is_pinned, is_archived, is_renamed
         ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      <Object?>[
        conversation.id,
        conversation.serverProfileId,
        conversation.title,
        hasUserMessage || conversation.isRenamed ? 1 : 0,
        conversation.selectedModel,
        conversation.systemPrompt,
        jsonEncode(conversation.generationOptions.toOllamaJson()),
        _toEpoch(conversation.createdAt),
        _toEpoch(conversation.updatedAt),
        conversation.isPinned ? 1 : 0,
        conversation.isArchived ? 1 : 0,
        conversation.isRenamed ? 1 : 0,
      ],
    );
    for (final message in thread.messages) {
      await _insertMessage(database, message);
      await _replaceMessageParts(database, message);
    }
  }

  Future<void> _replaceMessageParts(
    SqliteDatabase database,
    Message message,
  ) async {
    await database.execute(
      'DELETE FROM message_images WHERE message_id = ?',
      <Object?>[message.id],
    );
    await database.execute(
      'DELETE FROM tool_calls WHERE message_id = ?',
      <Object?>[message.id],
    );
    await database.execute(
      'DELETE FROM tool_results WHERE message_id = ?',
      <Object?>[message.id],
    );

    for (var index = 0; index < message.imageReferences.length; index++) {
      await database.execute(
        '''INSERT INTO message_images(message_id, position, reference)
           VALUES(?, ?, ?)''',
        <Object?>[
          message.id,
          index,
          _referenceCodec.encode(message.imageReferences[index]),
        ],
      );
    }
    for (var index = 0; index < message.toolCalls.length; index++) {
      final call = message.toolCalls[index];
      await database.execute(
        '''INSERT INTO tool_calls(id, message_id, position, name, arguments_json)
           VALUES(?, ?, ?, ?, ?)''',
        <Object?>[
          call.id,
          message.id,
          index,
          call.name,
          jsonEncode(call.arguments),
        ],
      );
    }
    for (var index = 0; index < message.toolResults.length; index++) {
      final result = message.toolResults[index];
      await database.execute(
        '''INSERT INTO tool_results(
             id, message_id, position, tool_call_id, content, is_error
           ) VALUES(?, ?, ?, ?, ?, ?)''',
        <Object?>[
          result.id,
          message.id,
          index,
          result.toolCallId,
          result.content,
          result.isError ? 1 : 0,
        ],
      );
    }
  }

  static void _validateQueuedPromptId(String value, String field) {
    if (value.trim().isEmpty) {
      throw FormatException('Queued prompt $field must not be empty.');
    }
  }

  static void _validateQueuedPrompt(QueuedPrompt prompt) {
    _validateQueuedPromptId(prompt.id, 'ID');
    _validateQueuedPromptId(prompt.conversationId, 'conversation ID');
    if (prompt.text.trim().isEmpty &&
        prompt.imageReferences.isEmpty &&
        prompt.documents.isEmpty) {
      throw const FormatException(
        'A queued prompt must contain text or an attachment.',
      );
    }
    if (utf8.encode(prompt.text).length > _maxQueuedPromptTextBytes) {
      throw const FormatException(
        'Queued prompt text exceeds the 65536 byte limit.',
      );
    }
    _validateMessage(
      Message(
        id: prompt.id,
        conversationId: prompt.conversationId,
        position: 0,
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: prompt.text,
        imageReferences: prompt.imageReferences,
        documents: prompt.documents,
        createdAt: prompt.createdAt,
        updatedAt: prompt.createdAt,
      ),
    );
  }

  static void _validateMessage(Message message) {
    if (message.id.trim().isEmpty) {
      throw const FormatException('message ID must not be empty');
    }
    if (message.conversationId.trim().isEmpty) {
      throw const FormatException('message conversation ID must not be empty');
    }
    if (message.position < 0) {
      throw const FormatException('message position must not be negative');
    }
    final callIds = <String>{};
    for (final call in message.toolCalls) {
      if (call.id.trim().isEmpty || !callIds.add(call.id)) {
        throw const FormatException(
          'tool call IDs must be non-empty and unique',
        );
      }
      if (call.name.trim().isEmpty) {
        throw const FormatException('tool call name must not be empty');
      }
      jsonEncode(call.arguments);
    }
    final resultIds = <String>{};
    for (final result in message.toolResults) {
      if (result.id.trim().isEmpty || !resultIds.add(result.id)) {
        throw const FormatException(
          'tool result IDs must be non-empty and unique',
        );
      }
      if (result.toolCallId.trim().isEmpty) {
        throw const FormatException('tool result call ID must not be empty');
      }
    }
    for (final reference in message.imageReferences) {
      if (reference.trim().isEmpty) {
        throw const FormatException('image reference must not be empty');
      }
    }
    if (message.documents.length > DocumentAttachment.maxPerMessage) {
      throw const FormatException(
        'a message cannot contain more than 4 documents',
      );
    }
    final documentIds = <String>{};
    for (final document in message.documents) {
      if (document.id.trim().isEmpty || !documentIds.add(document.id)) {
        throw const FormatException(
          'document IDs must be non-empty and unique within a message',
        );
      }
      if (document.name.trim().isEmpty) {
        throw const FormatException('document name must not be empty');
      }
      if (!_supportedDocumentMimeTypes.contains(document.mimeType)) {
        throw FormatException(
          'unsupported document MIME type ${document.mimeType}',
        );
      }
      if (document.reference.trim().isEmpty) {
        throw const FormatException('document reference must not be empty');
      }
      if (utf8.encode(document.text).length >
          DocumentAttachment.maxExtractedTextBytes) {
        throw const FormatException(
          'document extracted text exceeds the 65536 byte limit',
        );
      }
    }
  }

  static Future<void> _rejectReplacementIdentityCollisions(
    SqliteDatabase database, {
    required String conversationId,
    required int fromPosition,
    required Message replacement,
  }) async {
    Future<void> rejectCollision({
      required String table,
      required String id,
      required String label,
    }) async {
      final rows = await database.query(
        '''SELECT m.conversation_id, m.position
           FROM $table part
           JOIN messages m ON m.id = ${table == 'messages' ? 'part.id' : 'part.message_id'}
           WHERE part.id = ? LIMIT 1''',
        <Object?>[id],
      );
      if (rows.isEmpty) return;
      final belongsToRemovedTail =
          rows.single['conversation_id'] == conversationId &&
          _readInt(rows.single['position']) >= fromPosition;
      if (!belongsToRemovedTail) {
        throw FormatException('$label ID already exists outside replaced tail');
      }
    }

    await rejectCollision(
      table: 'messages',
      id: replacement.id,
      label: 'message',
    );
    for (final call in replacement.toolCalls) {
      await rejectCollision(
        table: 'tool_calls',
        id: call.id,
        label: 'tool call',
      );
    }
    for (final result in replacement.toolResults) {
      await rejectCollision(
        table: 'tool_results',
        id: result.id,
        label: 'tool result',
      );
    }
  }

  Future<void> _rejectSyncedIdentityCollisions(
    SqliteDatabase database, {
    required ConversationThread thread,
    required String? allowConversationId,
  }) async {
    final conversationId = thread.conversation.id;
    final conversationRows = await database.query(
      'SELECT id FROM conversations WHERE id = ? LIMIT 1',
      <Object?>[conversationId],
    );
    if (conversationRows.isNotEmpty && allowConversationId != conversationId) {
      throw FormatException(
        'Conversation ID $conversationId already belongs to local history.',
      );
    }

    Future<void> rejectPartCollision({
      required String table,
      required String id,
      required String label,
    }) async {
      final rows = await database.query(
        '''SELECT m.conversation_id
           FROM $table part
           JOIN messages m ON m.id = ${table == 'messages' ? 'part.id' : 'part.message_id'}
           WHERE part.id = ? LIMIT 1''',
        <Object?>[id],
      );
      if (rows.isEmpty ||
          rows.single['conversation_id'] == allowConversationId) {
        return;
      }
      throw FormatException(
        '$label ID $id already belongs to an unrelated conversation.',
      );
    }

    final incomingDocumentIds = <String>{};
    for (final message in thread.messages) {
      await rejectPartCollision(
        table: 'messages',
        id: message.id,
        label: 'Message',
      );
      for (final call in message.toolCalls) {
        await rejectPartCollision(
          table: 'tool_calls',
          id: call.id,
          label: 'Tool call',
        );
      }
      for (final result in message.toolResults) {
        await rejectPartCollision(
          table: 'tool_results',
          id: result.id,
          label: 'Tool result',
        );
      }
      incomingDocumentIds.addAll(
        message.documents.map((document) => document.id),
      );
    }

    if (incomingDocumentIds.isEmpty) return;
    final documentRows = await database.query(
      allowConversationId == null
          ? "SELECT conversation_id, documents_json FROM messages WHERE documents_json != '[]'"
          : "SELECT conversation_id, documents_json FROM messages WHERE conversation_id != ? AND documents_json != '[]'",
      allowConversationId == null
          ? const <Object?>[]
          : <Object?>[allowConversationId],
    );
    for (final row in documentRows) {
      for (final document in _decodeDocuments(row['documents_json'])) {
        if (incomingDocumentIds.contains(document.id)) {
          throw FormatException(
            'Document ID ${document.id} already belongs to an unrelated '
            'conversation.',
          );
        }
      }
    }
  }

  static void _validateReceiptToken(String token) {
    if (token.trim().isEmpty || token != token.trim()) {
      throw ArgumentError.value(
        token,
        'receiptToken',
        'must be a non-empty token without surrounding whitespace',
      );
    }
    if (token.length > 512) {
      throw ArgumentError.value(
        token,
        'receiptToken',
        'must be 512 characters or fewer',
      );
    }
  }

  static Future<bool> _hasSyncReceipt(
    SqliteDatabase database,
    String token,
  ) async {
    final rows = await database.query(
      'SELECT 1 FROM sync_receipts WHERE token = ? LIMIT 1',
      <Object?>[token],
    );
    return rows.isNotEmpty;
  }

  static Future<void> _insertSyncReceipt(
    SqliteDatabase database,
    String token,
  ) => database.execute('INSERT INTO sync_receipts(token) VALUES(?)', <Object?>[
    token,
  ]);

  static void _validateImportedThreads(List<ConversationThread> threads) {
    final conversationIds = <String>{};
    final messageIds = <String>{};
    final callIds = <String>{};
    final resultIds = <String>{};
    final documentIds = <String>{};
    for (final thread in threads) {
      final conversation = thread.conversation;
      if (conversation.id.trim().isEmpty ||
          !conversationIds.add(conversation.id)) {
        throw const FormatException(
          'conversation IDs must be non-empty and unique',
        );
      }
      if (conversation.serverProfileId.trim().isEmpty) {
        throw const FormatException('server profile ID must not be empty');
      }
      conversation.generationOptions.validate();
      for (var index = 0; index < thread.messages.length; index++) {
        final message = thread.messages[index];
        _validateMessage(message);
        if (message.conversationId != conversation.id) {
          throw const FormatException(
            'message conversation ID must match its conversation',
          );
        }
        if (message.position != index) {
          throw const FormatException(
            'message positions must be contiguous and start at zero',
          );
        }
        if (!messageIds.add(message.id)) {
          throw const FormatException('message IDs must be unique');
        }
        for (final document in message.documents) {
          if (!documentIds.add(document.id)) {
            throw const FormatException('document IDs must be unique');
          }
        }
        for (final call in message.toolCalls) {
          if (!callIds.add(call.id)) {
            throw const FormatException('tool call IDs must be unique');
          }
        }
        for (final result in message.toolResults) {
          if (!resultIds.add(result.id)) {
            throw const FormatException('tool result IDs must be unique');
          }
        }
      }
    }
  }

  static int _toEpoch(DateTime value) => value.toUtc().microsecondsSinceEpoch;

  static DateTime _fromEpoch(Object? value) =>
      DateTime.fromMicrosecondsSinceEpoch(_readInt(value), isUtc: true);

  static int _readInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    throw FormatException('expected integer, got $value');
  }

  static Map<String, Object?> _decodeToolArguments(Object? value) {
    if (value is! String) return const <String, Object?>{};
    try {
      final decoded = jsonDecode(value);
      return decoded is Map
          ? Map<String, Object?>.from(decoded)
          : const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }

  String _encodeImageReferences(List<String> references) => jsonEncode(
    references.map(_referenceCodec.encode).toList(growable: false),
  );

  List<String> _decodeImageReferences(Object? value) {
    if (value is! String) {
      throw const FormatException('image references must be JSON text');
    }
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      throw const FormatException('image references must be a JSON array');
    }
    return decoded
        .map((entry) {
          if (entry is! String) {
            throw const FormatException('image reference must be text');
          }
          return _referenceCodec.decode(entry);
        })
        .toList(growable: false);
  }

  String _encodeDocuments(List<DocumentAttachment> documents) => jsonEncode(
    documents
        .map(
          (document) => document
              .copyWith(reference: _referenceCodec.encode(document.reference))
              .toJson(),
        )
        .toList(),
  );

  List<DocumentAttachment> _decodeDocuments(Object? value) {
    if (value == null) return const <DocumentAttachment>[];
    if (value is! String) {
      throw const FormatException('documents must be JSON text');
    }
    final decoded = jsonDecode(value);
    if (decoded is! List) {
      throw const FormatException('documents must be a JSON array');
    }
    return decoded
        .map((entry) {
          if (entry is! Map) {
            throw const FormatException('document must be a JSON object');
          }
          final document = DocumentAttachment.fromJson(
            Map<String, Object?>.from(entry),
          );
          return document.copyWith(
            reference: _referenceCodec.decode(document.reference),
          );
        })
        .toList(growable: false);
  }

  Map<String, Object?> _encodeDraft(Map<String, Object?> value) =>
      _transformDraft(value, _referenceCodec.encode);

  Map<String, Object?> _decodeDraft(Map<String, Object?> value) =>
      _transformDraft(value, _referenceCodec.decode);

  static Map<String, Object?> _transformDraft(
    Map<String, Object?> value,
    String Function(String reference) transform,
  ) {
    final result = Map<String, Object?>.from(value);
    final image = result['image'];
    if (image != null) {
      if (image is! String) {
        throw const FormatException('draft image reference must be text');
      }
      result['image'] = transform(image);
    }
    final images = result['images'];
    if (images != null) {
      if (images is! List) {
        throw const FormatException('draft image references must be an array');
      }
      result['images'] = <String>[
        for (final reference in images)
          if (reference is String)
            transform(reference)
          else
            throw const FormatException('draft image reference must be text'),
      ];
    }
    final rawDocuments = result['documents'];
    if (rawDocuments != null) {
      if (rawDocuments is! List) {
        throw const FormatException('draft documents must be a JSON array');
      }
      result['documents'] = <Map<String, Object?>>[
        for (final entry in rawDocuments)
          if (entry is Map)
            () {
              final document = DocumentAttachment.fromJson(
                Map<String, Object?>.from(entry),
              );
              return document
                  .copyWith(reference: transform(document.reference))
                  .toJson();
            }()
          else
            throw const FormatException('draft document must be a JSON object'),
      ];
    }
    return result;
  }

  static GenerationOptions _decodeGenerationOptions(Object? value) {
    if (value == null) return const GenerationOptions();
    if (value is! String) {
      throw FormatException('generation options must be JSON text');
    }
    final decoded = jsonDecode(value);
    if (decoded is! Map) {
      throw FormatException('generation options must be a JSON object');
    }
    return GenerationOptions.fromJson(Map<String, Object?>.from(decoded));
  }

  static T _enumByName<T extends Enum>(List<T> values, String name) =>
      values.firstWhere(
        (value) => value.name == name,
        orElse: () => throw FormatException('unknown enum value $name'),
      );

  static const _supportedDocumentMimeTypes = <String>{
    'application/pdf',
    'text/plain',
    'text/markdown',
  };

  static const _maxQueuedPromptTextBytes = 64 * 1024;

  static const _schemaVersionOne = <String>[
    '''CREATE TABLE conversations(
         id TEXT PRIMARY KEY,
         title TEXT NOT NULL,
         title_from_first_user INTEGER NOT NULL DEFAULT 0 CHECK(title_from_first_user IN (0, 1)),
         selected_model TEXT NOT NULL,
         system_prompt TEXT NOT NULL,
         created_at INTEGER NOT NULL,
         updated_at INTEGER NOT NULL
       )''',
    '''CREATE TABLE messages(
         id TEXT PRIMARY KEY,
         conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
         position INTEGER NOT NULL,
         role TEXT NOT NULL CHECK(role IN ('system', 'user', 'assistant', 'tool')),
         status TEXT NOT NULL CHECK(status IN (
           'queued', 'streaming', 'complete', 'partial', 'interrupted', 'failed'
         )),
         content TEXT NOT NULL,
         reasoning TEXT,
         created_at INTEGER NOT NULL,
         updated_at INTEGER NOT NULL,
         UNIQUE(conversation_id, position)
       )''',
    '''CREATE TABLE message_images(
         message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
         position INTEGER NOT NULL,
         reference TEXT NOT NULL,
         PRIMARY KEY(message_id, position)
       )''',
    '''CREATE TABLE tool_calls(
         id TEXT PRIMARY KEY,
         message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
         position INTEGER NOT NULL,
         name TEXT NOT NULL,
         arguments_json TEXT NOT NULL,
         UNIQUE(message_id, position)
       )''',
    '''CREATE TABLE tool_results(
         id TEXT PRIMARY KEY,
         message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
         position INTEGER NOT NULL,
         tool_call_id TEXT NOT NULL,
         content TEXT NOT NULL,
         is_error INTEGER NOT NULL DEFAULT 0 CHECK(is_error IN (0, 1)),
         UNIQUE(message_id, position)
       )''',
    'CREATE INDEX conversations_recent ON conversations(updated_at DESC, created_at DESC, id ASC)',
    '''CREATE INDEX messages_in_conversation
       ON messages(conversation_id, position ASC, created_at ASC, id ASC)''',
    'CREATE INDEX tool_results_by_call ON tool_results(tool_call_id)',
  ];
}
