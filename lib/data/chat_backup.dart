import 'dart:convert';

import '../domain/conversation.dart';
import '../domain/document_attachment.dart';
import '../domain/generation_options.dart';
import '../domain/message.dart';
import '../domain/tool_call.dart';
import 'conversation_store.dart';

typedef BackupAttachmentReader = Future<List<int>> Function(String reference);
typedef BackupAttachmentWriter = Future<String> Function(
  BackupAttachment attachment,
  String conversationId,
);
typedef BackupAttachmentCleanup = Future<void> Function(String reference);
typedef BackupIdAllocator = String Function();

final class ChatBackupLimits {
  const ChatBackupLimits({
    this.maxJsonBytes = 128 * 1024 * 1024,
    this.maxAttachmentBytes = 8 * 1024 * 1024,
    this.maxProfiles = 10000,
    this.maxConversations = 100000,
    this.maxMessages = 1000000,
    this.maxAttachments = 100000,
  });

  final int maxJsonBytes;
  final int maxAttachmentBytes;
  final int maxProfiles;
  final int maxConversations;
  final int maxMessages;
  final int maxAttachments;
}

final class BackupServerProfile {
  const BackupServerProfile({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
  });

  final String id;
  final String name;
  final String protocol;
  final String baseUrl;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'protocol': protocol,
    'baseUrl': baseUrl,
  };
}

final class BackupAttachment {
  BackupAttachment({required this.sourceName, required List<int> bytes})
    : bytes = List<int>.unmodifiable(bytes);

  final String sourceName;
  final List<int> bytes;
}

final class ChatBackupInspection {
  const ChatBackupInspection({
    required this.version,
    required this.profiles,
    required this.conversationCount,
    required this.messageCount,
    required this.attachmentCount,
  });

  final int version;
  final List<BackupServerProfile> profiles;
  final int conversationCount;
  final int messageCount;
  final int attachmentCount;
}

final class ChatBackupImportResult {
  const ChatBackupImportResult({
    required this.conversations,
    required this.messages,
    required this.attachments,
    this.cleanupWarning,
  });

  final int conversations;
  final int messages;
  final int attachments;
  final String? cleanupWarning;
}

final class ChatBackupImportException implements Exception {
  const ChatBackupImportException(this.message, this.cause);

  final String message;
  final Object cause;

  @override
  String toString() => '$message Cause: $cause';
}

/// Versioned portable chat-history backup and readable conversation export.
///
/// Drafts use their own durable store and are intentionally outside version 1
/// because controller-owned draft scopes require separate remapping rules.
final class ChatBackup {
  const ChatBackup(this._store, {this.limits = const ChatBackupLimits()});

  static const format = 'mobilellama-chat-backup';
  static const version = 1;

  final ConversationStore _store;
  final ChatBackupLimits limits;

  ChatBackupInspection inspectJson(String source) {
    final parsed = _parse(source);
    return ChatBackupInspection(
      version: version,
      profiles: List<BackupServerProfile>.unmodifiable(parsed.profiles),
      conversationCount: parsed.conversations.length,
      messageCount: parsed.messageCount,
      attachmentCount: parsed.attachmentCount,
    );
  }

  Future<String> exportJson({
    required List<BackupServerProfile> serverProfiles,
    required BackupAttachmentReader readAttachment,
    Set<String>? conversationIds,
  }) async {
    _validateLimits();
    final profiles = List<BackupServerProfile>.of(serverProfiles);
    if (profiles.length > limits.maxProfiles) {
      throw StateError('Too many server profiles to export.');
    }
    final profileIds = <String>{};
    for (final profile in profiles) {
      _validateProfile(profile, profileIds);
    }

    final allConversations = await _store.listAllConversations(
      includeEmpty: true,
    );
    final selectedIds = conversationIds == null
        ? null
        : Set<String>.of(conversationIds);
    if (selectedIds != null) {
      if (selectedIds.any((id) => id.trim().isEmpty)) {
        throw ArgumentError.value(
          conversationIds,
          'conversationIds',
          'must contain only non-empty IDs',
        );
      }
      final knownIds = allConversations
          .map((conversation) => conversation.id)
          .toSet();
      final missingIds = selectedIds.difference(knownIds).toList()..sort();
      if (missingIds.isNotEmpty) {
        throw ArgumentError.value(
          missingIds,
          'conversationIds',
          'contains unknown conversation IDs',
        );
      }
    }
    final conversations = selectedIds == null
        ? allConversations
        : allConversations
              .where((conversation) => selectedIds.contains(conversation.id))
              .toList(growable: false);
    if (conversations.length > limits.maxConversations) {
      throw StateError('Too many conversations to export.');
    }

    var messageCount = 0;
    var attachmentCount = 0;
    final documentIds = <String>{};
    final encodedConversations = <Map<String, Object?>>[];
    for (final conversation in conversations) {
      if (!profileIds.contains(conversation.serverProfileId)) {
        throw StateError(
          'Conversation ${conversation.id} uses server profile '
          '${conversation.serverProfileId}, which was not supplied.',
        );
      }
      final thread = await _store.openConversation(
        serverProfileId: conversation.serverProfileId,
        id: conversation.id,
      );
      if (thread == null) {
        throw StateError(
          'Conversation ${conversation.id} disappeared during export.',
        );
      }
      messageCount += thread.messages.length;
      if (messageCount > limits.maxMessages) {
        throw StateError('Too many messages to export.');
      }

      final messages = <Map<String, Object?>>[];
      for (final message in thread.messages) {
        final providerTranscript = message.providerTranscriptJson;
        if (providerTranscript != null) {
          _validateProviderTranscript(
            providerTranscript,
            'message ${message.id} provider transcript',
          );
        }
        final images = <Map<String, Object?>>[];
        for (final reference in message.imageReferences) {
          attachmentCount++;
          if (attachmentCount > limits.maxAttachments) {
            throw StateError('Too many image attachments to export.');
          }
          final bytes = await readAttachment(reference);
          if (bytes.length > limits.maxAttachmentBytes) {
            throw StateError(
              'Image attachment exceeds the ${limits.maxAttachmentBytes} '
              'byte backup limit.',
            );
          }
          images.add(<String, Object?>{
            'name': _safeSourceName(reference),
            'base64': base64Encode(bytes),
          });
        }
        if (message.documents.length > DocumentAttachment.maxPerMessage) {
          throw StateError(
            'Message ${message.id} contains more than '
            '${DocumentAttachment.maxPerMessage} documents.',
          );
        }
        final documents = <Map<String, Object?>>[];
        for (final document in message.documents) {
          _validateExportDocument(document, message.id);
          if (!documentIds.add(document.id)) {
            throw StateError('Duplicate document ID ${document.id}.');
          }
          attachmentCount++;
          if (attachmentCount > limits.maxAttachments) {
            throw StateError('Too many attachments to export.');
          }
          final bytes = await readAttachment(document.reference);
          if (bytes.length > limits.maxAttachmentBytes) {
            throw StateError(
              'Document ${document.name} exceeds the '
              '${limits.maxAttachmentBytes} byte backup limit.',
            );
          }
          documents.add(<String, Object?>{
            'id': document.id,
            'name': document.name,
            'mimeType': document.mimeType,
            'text': document.text,
            'base64': base64Encode(bytes),
          });
        }
        messages.add(<String, Object?>{
          'id': message.id,
          'position': message.position,
          'role': message.role.name,
          'status': message.status.name,
          'content': message.content,
          if (message.reasoning != null) 'reasoning': message.reasoning,
          if (message.providerTranscriptJson != null)
            'providerTranscriptJson': message.providerTranscriptJson,
          'images': images,
          'documents': documents,
          'toolCalls': message.toolCalls.map((call) => call.toJson()).toList(),
          'toolResults': message.toolResults
              .map((result) => result.toJson())
              .toList(),
          'createdAt': message.createdAt.toUtc().toIso8601String(),
          'updatedAt': message.updatedAt.toUtc().toIso8601String(),
        });
      }
      encodedConversations.add(<String, Object?>{
        'id': conversation.id,
        'serverProfileId': conversation.serverProfileId,
        'title': conversation.title,
        'isPinned': conversation.isPinned,
        'isArchived': conversation.isArchived,
        'isRenamed': conversation.isRenamed,
        'selectedModel': conversation.selectedModel,
        'systemPrompt': conversation.systemPrompt,
        'generationOptions': conversation.generationOptions.toOllamaJson(),
        'createdAt': conversation.createdAt.toUtc().toIso8601String(),
        'updatedAt': conversation.updatedAt.toUtc().toIso8601String(),
        'messages': messages,
      });
    }

    final source = const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'format': format,
      'version': version,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'serverProfiles': profiles.map((profile) => profile.toJson()).toList(),
      'conversations': encodedConversations,
    });
    if (utf8.encode(source).length > limits.maxJsonBytes) {
      throw StateError(
        'Backup exceeds the ${limits.maxJsonBytes} byte JSON limit.',
      );
    }
    return source;
  }

  Future<ChatBackupImportResult> importJson({
    required String json,
    required Map<String, String> serverProfileMappings,
    required BackupIdAllocator allocateId,
    required BackupAttachmentWriter writeAttachment,
    required BackupAttachmentCleanup deleteAttachment,
  }) async {
    final parsed = _parse(json);
    _validateServerProfileMappings(parsed, serverProfileMappings);

    final allocatedIds = <String>{};
    String nextId(String entity) {
      final id = allocateId();
      if (id.trim().isEmpty) {
        throw FormatException('Allocated $entity ID must not be empty.');
      }
      if (!allocatedIds.add(id)) {
        throw FormatException('Allocated $entity ID $id is not unique.');
      }
      return id;
    }

    final conversationIds = <String, String>{};
    final messageIds = <String, String>{};
    final toolCallIds = <String, String>{};
    final toolResultIds = <String, String>{};
    final documentIds = <String, String>{};
    for (final source in parsed.conversations) {
      conversationIds[source.conversation.id] = nextId('conversation');
      for (final parsedMessage in source.messages) {
        final message = parsedMessage.message;
        messageIds[message.id] = nextId('message');
        for (final document in parsedMessage.documents) {
          documentIds[document.id] = nextId('document');
        }
        for (final call in message.toolCalls) {
          toolCallIds[call.id] = nextId('tool call');
        }
        for (final result in message.toolResults) {
          toolResultIds[result.id] = nextId('tool result');
        }
      }
    }

    final writtenReferences = <String>[];
    final uniqueWrittenReferences = <String>{};
    try {
      final importedThreads = <ConversationThread>[];
      for (final source in parsed.conversations) {
        final originalConversation = source.conversation;
        final conversationId = conversationIds[originalConversation.id]!;
        importedThreads.add(
          await _restoreConversation(
            source: source,
            conversationId: conversationId,
            serverProfileId:
                serverProfileMappings[originalConversation.serverProfileId]!,
            messageIds: messageIds,
            toolCallIds: toolCallIds,
            toolResultIds: toolResultIds,
            documentIds: documentIds,
            writeAttachment: writeAttachment,
            uniqueWrittenReferences: uniqueWrittenReferences,
            writtenReferences: writtenReferences,
          ),
        );
      }

      await _store.importThreadsAtomically(importedThreads);
      return ChatBackupImportResult(
        conversations: importedThreads.length,
        messages: parsed.messageCount,
        attachments: parsed.attachmentCount,
      );
    } on Object catch (error, stackTrace) {
      final cleanupError = await _cleanupPreparedAttachments(
        writtenReferences,
        deleteAttachment,
      );
      if (cleanupError != null) {
        throw ChatBackupImportException(
          'Backup import failed and a prepared attachment could not be '
          'cleaned up.',
          cleanupError,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<ChatBackupImportResult> applySyncedJson({
    required String json,
    required String targetConversationId,
    required String receiptToken,
    bool asConflictCopy = false,
    required Map<String, String> serverProfileMappings,
    required BackupIdAllocator allocateId,
    required BackupAttachmentWriter writeAttachment,
    required BackupAttachmentCleanup deleteAttachment,
  }) async {
    final parsed = _parse(json);
    if (parsed.conversations.length != 1) {
      throw const FormatException(
        'A synced snapshot must contain exactly one conversation.',
      );
    }
    _validateServerProfileMappings(parsed, serverProfileMappings);
    final targetId = targetConversationId.trim();
    if (targetId.isEmpty || targetId != targetConversationId) {
      throw ArgumentError.value(
        targetConversationId,
        'targetConversationId',
        'must be a non-empty ID without surrounding whitespace',
      );
    }
    final source = parsed.conversations.single;
    final sourceConversation = source.conversation;
    if (!asConflictCopy && sourceConversation.id != targetId) {
      throw FormatException(
        'Synced conversation ${sourceConversation.id} does not match target '
        '$targetId.',
      );
    }
    if (asConflictCopy && sourceConversation.id == targetId) {
      throw const FormatException(
        'A conflict copy must use a new conversation ID.',
      );
    }
    if (await _store.hasSyncReceipt(receiptToken)) {
      return const ChatBackupImportResult(
        conversations: 0,
        messages: 0,
        attachments: 0,
      );
    }

    final localConversations = await _store.listAllConversations(
      includeEmpty: true,
    );
    Conversation? existingTarget;
    for (final conversation in localConversations) {
      if (conversation.id == targetId) {
        existingTarget = conversation;
        break;
      }
    }
    if (asConflictCopy && existingTarget != null) {
      throw FormatException(
        'Conflict-copy target $targetId already belongs to local history.',
      );
    }
    final oldReferences = <String>{};
    if (!asConflictCopy && existingTarget != null) {
      final existingThread = await _store.openConversation(
        serverProfileId: existingTarget.serverProfileId,
        id: existingTarget.id,
      );
      if (existingThread == null) {
        throw StateError(
          'Conversation $targetId disappeared before sync could apply.',
        );
      }
      for (final message in existingThread.messages) {
        oldReferences.addAll(message.imageReferences);
        oldReferences.addAll(
          message.documents.map((document) => document.reference),
        );
      }
      // Replacement cascades away the local recovery checkpoint in the same
      // transaction, so its now-unreferenced media is released too.
      oldReferences.addAll(await _store.recoveryCheckpointReferences(targetId));
    }

    final allocatedIds = <String>{targetId};
    String nextId(String entity) {
      final id = allocateId();
      if (id.trim().isEmpty) {
        throw FormatException('Allocated $entity ID must not be empty.');
      }
      if (!allocatedIds.add(id)) {
        throw FormatException('Allocated $entity ID $id is not unique.');
      }
      return id;
    }

    final messageIds = <String, String>{};
    final toolCallIds = <String, String>{};
    final toolResultIds = <String, String>{};
    final documentIds = <String, String>{};
    for (final parsedMessage in source.messages) {
      final message = parsedMessage.message;
      messageIds[message.id] = asConflictCopy ? nextId('message') : message.id;
      for (final document in parsedMessage.documents) {
        documentIds[document.id] = asConflictCopy
            ? nextId('document')
            : document.id;
      }
      for (final call in message.toolCalls) {
        toolCallIds[call.id] = asConflictCopy ? nextId('tool call') : call.id;
      }
      for (final result in message.toolResults) {
        toolResultIds[result.id] = asConflictCopy
            ? nextId('tool result')
            : result.id;
      }
    }

    final writtenReferences = <String>[];
    final uniqueWrittenReferences = <String>{};
    late final ConversationThread thread;
    bool applied;
    try {
      thread = await _restoreConversation(
        source: source,
        conversationId: targetId,
        serverProfileId:
            serverProfileMappings[sourceConversation.serverProfileId]!,
        messageIds: messageIds,
        toolCallIds: toolCallIds,
        toolResultIds: toolResultIds,
        documentIds: documentIds,
        writeAttachment: writeAttachment,
        uniqueWrittenReferences: uniqueWrittenReferences,
        writtenReferences: writtenReferences,
        title: asConflictCopy
            ? '${sourceConversation.title} (conflict copy)'
            : null,
        isRenamed: asConflictCopy ? true : null,
      );
      applied = await _store.applySyncedThreadAtomically(
        thread,
        receiptToken: receiptToken,
        replaceExisting: !asConflictCopy,
      );
    } on Object catch (error, stackTrace) {
      final cleanupError = await _cleanupPreparedAttachments(
        writtenReferences,
        deleteAttachment,
      );
      if (cleanupError != null) {
        throw ChatBackupImportException(
          'Synced snapshot failed and a prepared attachment could not be '
          'cleaned up.',
          cleanupError,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (!applied) {
      final cleanupError = await _cleanupPreparedAttachments(
        writtenReferences,
        deleteAttachment,
      );
      if (cleanupError != null) {
        throw ChatBackupImportException(
          'Synced snapshot was already applied, but a concurrently prepared '
          'attachment could not be cleaned up.',
          cleanupError,
        );
      }
      return const ChatBackupImportResult(
        conversations: 0,
        messages: 0,
        attachments: 0,
      );
    }

    Object? oldCleanupError;
    for (final reference in oldReferences) {
      try {
        if (!await _store.isAttachmentReferenceInUse(reference)) {
          await deleteAttachment(reference);
        }
      } on Object catch (error) {
        oldCleanupError ??= error;
      }
    }
    return ChatBackupImportResult(
      conversations: 1,
      messages: parsed.messageCount,
      attachments: parsed.attachmentCount,
      cleanupWarning: oldCleanupError == null
          ? null
          : 'The synced conversation was applied, but an unused attachment '
                'could not be removed.',
    );
  }

  Future<String> exportConversationMarkdown({
    required String serverProfileId,
    required String conversationId,
  }) async {
    final thread = await _store.openConversation(
      serverProfileId: serverProfileId,
      id: conversationId,
    );
    if (thread == null) {
      throw ArgumentError.value(
        conversationId,
        'conversationId',
        'unknown conversation',
      );
    }
    final conversation = thread.conversation;
    final output = StringBuffer()
      ..writeln('# ${_escapeHeading(conversation.title)}')
      ..writeln()
      ..writeln('_Model: ${conversation.selectedModel}_');
    if (conversation.systemPrompt.trim().isNotEmpty) {
      output
        ..writeln()
        ..writeln('## System instruction')
        ..writeln()
        ..writeln(conversation.systemPrompt);
    }
    for (final message in thread.messages) {
      output
        ..writeln()
        ..writeln('## ${_roleLabel(message.role)}')
        ..writeln();
      if (message.content.isEmpty) {
        output.writeln('_No text content._');
      } else {
        output.writeln(message.content);
      }
      for (final reference in message.imageReferences) {
        output.writeln('\n_Image attachment: ${_safeSourceName(reference)}_');
      }
      for (final document in message.documents) {
        output
          ..writeln()
          ..writeln('### Attached document: ${_escapeHeading(document.name)}')
          ..writeln()
          ..writeln('_Type: ${document.mimeType}_')
          ..writeln()
          ..writeln(
            document.text.isEmpty ? '_No extracted text._' : document.text,
          );
      }
      final reasoning = message.reasoning;
      if (reasoning != null && reasoning.isNotEmpty) {
        output
          ..writeln()
          ..writeln('### Reasoning')
          ..writeln()
          ..writeln(reasoning);
      }
      for (final call in message.toolCalls) {
        output
          ..writeln()
          ..writeln('### Tool call: ${_escapeHeading(call.name)}')
          ..writeln()
          ..writeln(
            _indent(const JsonEncoder.withIndent('  ').convert(call.arguments)),
          );
      }
      for (final result in message.toolResults) {
        output
          ..writeln()
          ..writeln('### Tool result${result.isError ? ' (error)' : ''}')
          ..writeln()
          ..writeln(_indent(result.content));
      }
    }
    return output.toString().trimRight();
  }

  _ParsedBackup _parse(String source) {
    _validateLimits();
    if (source.length > limits.maxJsonBytes ||
        utf8.encode(source).length > limits.maxJsonBytes) {
      throw FormatException(
        'Backup exceeds the ${limits.maxJsonBytes} byte JSON limit.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (error) {
      throw FormatException('Invalid backup JSON: ${error.message}.');
    }
    final root = _object(decoded, 'backup');
    if (_string(root['format'], 'format') != format) {
      throw const FormatException('Unrecognized MobileLlama backup format.');
    }
    final parsedVersion = _integer(root['version'], 'version');
    if (parsedVersion != version) {
      throw FormatException(
        'Unsupported MobileLlama backup version $parsedVersion.',
      );
    }
    _date(root['exportedAt'], 'exportedAt');

    final rawProfiles = _array(root['serverProfiles'], 'serverProfiles');
    if (rawProfiles.length > limits.maxProfiles) {
      throw const FormatException('Backup contains too many server profiles.');
    }
    final profileIds = <String>{};
    final profiles = <BackupServerProfile>[];
    for (var index = 0; index < rawProfiles.length; index++) {
      final json = _object(rawProfiles[index], 'serverProfiles[$index]');
      final profile = BackupServerProfile(
        id: _nonEmptyString(json['id'], 'serverProfiles[$index].id'),
        name: _nonEmptyString(json['name'], 'serverProfiles[$index].name'),
        protocol: _string(json['protocol'], 'serverProfiles[$index].protocol'),
        baseUrl: _nonEmptyString(
          json['baseUrl'],
          'serverProfiles[$index].baseUrl',
        ),
      );
      _validateProfile(profile, profileIds, malformedInput: true);
      profiles.add(profile);
    }

    final rawConversations = _array(root['conversations'], 'conversations');
    if (rawConversations.length > limits.maxConversations) {
      throw const FormatException('Backup contains too many conversations.');
    }
    final conversationIds = <String>{};
    final messageIds = <String>{};
    final toolCallIds = <String>{};
    final toolResultIds = <String>{};
    final documentIds = <String>{};
    final conversations = <_ParsedConversation>[];
    var messageCount = 0;
    var attachmentCount = 0;
    for (
      var conversationIndex = 0;
      conversationIndex < rawConversations.length;
      conversationIndex++
    ) {
      final path = 'conversations[$conversationIndex]';
      final json = _object(rawConversations[conversationIndex], path);
      final id = _nonEmptyString(json['id'], '$path.id');
      if (!conversationIds.add(id)) {
        throw FormatException('Duplicate conversation ID $id.');
      }
      final serverProfileId = _nonEmptyString(
        json['serverProfileId'],
        '$path.serverProfileId',
      );
      if (!profileIds.contains(serverProfileId)) {
        throw FormatException(
          '$path references unknown server profile $serverProfileId.',
        );
      }
      final generationJson = _object(
        json['generationOptions'],
        '$path.generationOptions',
      );
      final generationOptions = GenerationOptions.fromJson(generationJson);
      final conversation = Conversation(
        id: id,
        serverProfileId: serverProfileId,
        title: _nonEmptyString(json['title'], '$path.title'),
        selectedModel: _string(json['selectedModel'], '$path.selectedModel'),
        systemPrompt: _string(json['systemPrompt'], '$path.systemPrompt'),
        createdAt: _date(json['createdAt'], '$path.createdAt'),
        updatedAt: _date(json['updatedAt'], '$path.updatedAt'),
        generationOptions: generationOptions,
        isPinned: _boolean(json['isPinned'], '$path.isPinned'),
        isArchived: _boolean(json['isArchived'], '$path.isArchived'),
        isRenamed: _boolean(json['isRenamed'], '$path.isRenamed'),
      );
      final rawMessages = _array(json['messages'], '$path.messages');
      messageCount += rawMessages.length;
      if (messageCount > limits.maxMessages) {
        throw const FormatException('Backup contains too many messages.');
      }
      final messages = <_ParsedMessage>[];
      final conversationCallIds = <String>{};
      final conversationResults = <ToolResult>[];
      for (
        var messageIndex = 0;
        messageIndex < rawMessages.length;
        messageIndex++
      ) {
        final messagePath = '$path.messages[$messageIndex]';
        final messageJson = _object(rawMessages[messageIndex], messagePath);
        final messageId = _nonEmptyString(messageJson['id'], '$messagePath.id');
        if (!messageIds.add(messageId)) {
          throw FormatException('Duplicate message ID $messageId.');
        }
        final position = _integer(
          messageJson['position'],
          '$messagePath.position',
        );
        if (position != messageIndex) {
          throw FormatException(
            '$messagePath.position must be contiguous and start at zero.',
          );
        }
        final providerTranscript = _nullableString(
          messageJson['providerTranscriptJson'],
          '$messagePath.providerTranscriptJson',
        );
        if (providerTranscript != null) {
          _validateProviderTranscript(
            providerTranscript,
            '$messagePath.providerTranscriptJson',
          );
        }

        final calls = <ToolCall>[];
        final rawCalls = _array(
          messageJson['toolCalls'],
          '$messagePath.toolCalls',
        );
        for (var callIndex = 0; callIndex < rawCalls.length; callIndex++) {
          final callPath = '$messagePath.toolCalls[$callIndex]';
          final callJson = _object(rawCalls[callIndex], callPath);
          final callId = _nonEmptyString(callJson['id'], '$callPath.id');
          if (!toolCallIds.add(callId)) {
            throw FormatException('Duplicate tool call ID $callId.');
          }
          conversationCallIds.add(callId);
          calls.add(
            ToolCall(
              id: callId,
              name: _nonEmptyString(callJson['name'], '$callPath.name'),
              arguments: _object(callJson['arguments'], '$callPath.arguments'),
            ),
          );
        }

        final results = <ToolResult>[];
        final rawResults = _array(
          messageJson['toolResults'],
          '$messagePath.toolResults',
        );
        for (
          var resultIndex = 0;
          resultIndex < rawResults.length;
          resultIndex++
        ) {
          final resultPath = '$messagePath.toolResults[$resultIndex]';
          final resultJson = _object(rawResults[resultIndex], resultPath);
          final resultId = _nonEmptyString(resultJson['id'], '$resultPath.id');
          if (!toolResultIds.add(resultId)) {
            throw FormatException('Duplicate tool result ID $resultId.');
          }
          final result = ToolResult(
            id: resultId,
            toolCallId: _nonEmptyString(
              resultJson['toolCallId'],
              '$resultPath.toolCallId',
            ),
            content: _string(resultJson['content'], '$resultPath.content'),
            isError: _boolean(resultJson['isError'], '$resultPath.isError'),
          );
          results.add(result);
          conversationResults.add(result);
        }

        final imageAttachments = <BackupAttachment>[];
        final rawImages = _array(messageJson['images'], '$messagePath.images');
        attachmentCount += rawImages.length;
        if (attachmentCount > limits.maxAttachments) {
          throw const FormatException('Backup contains too many attachments.');
        }
        for (var imageIndex = 0; imageIndex < rawImages.length; imageIndex++) {
          final imagePath = '$messagePath.images[$imageIndex]';
          final imageJson = _object(rawImages[imageIndex], imagePath);
          imageAttachments.add(_parseAttachment(imageJson, imagePath));
        }

        final rawDocuments = messageJson.containsKey('documents')
            ? _array(messageJson['documents'], '$messagePath.documents')
            : const <Object?>[];
        if (rawDocuments.length > DocumentAttachment.maxPerMessage) {
          throw FormatException(
            '$messagePath.documents cannot contain more than '
            '${DocumentAttachment.maxPerMessage} items.',
          );
        }
        attachmentCount += rawDocuments.length;
        if (attachmentCount > limits.maxAttachments) {
          throw const FormatException('Backup contains too many attachments.');
        }
        final documents = <_ParsedDocument>[];
        for (
          var documentIndex = 0;
          documentIndex < rawDocuments.length;
          documentIndex++
        ) {
          final documentPath = '$messagePath.documents[$documentIndex]';
          final documentJson = _object(
            rawDocuments[documentIndex],
            documentPath,
          );
          final documentId = _nonEmptyString(
            documentJson['id'],
            '$documentPath.id',
          );
          if (!documentIds.add(documentId)) {
            throw FormatException('Duplicate document ID $documentId.');
          }
          final name = _nonEmptyString(
            documentJson['name'],
            '$documentPath.name',
          );
          if (!_isSafeFileName(name)) {
            throw FormatException(
              '$documentPath.name must be a plain filename.',
            );
          }
          final mimeType = _string(
            documentJson['mimeType'],
            '$documentPath.mimeType',
          );
          if (!_supportedDocumentMimeTypes.contains(mimeType)) {
            throw FormatException(
              '$documentPath.mimeType has unsupported value $mimeType.',
            );
          }
          final text = _string(documentJson['text'], '$documentPath.text');
          if (utf8.encode(text).length >
              DocumentAttachment.maxExtractedTextBytes) {
            throw FormatException(
              '$documentPath.text exceeds the '
              '${DocumentAttachment.maxExtractedTextBytes} byte limit.',
            );
          }
          documents.add(
            _ParsedDocument(
              id: documentId,
              name: name,
              mimeType: mimeType,
              text: text,
              attachment: _parseAttachment(documentJson, documentPath),
            ),
          );
        }

        messages.add(
          _ParsedMessage(
            message: Message(
              id: messageId,
              conversationId: id,
              position: position,
              role: _enumByName(
                MessageRole.values,
                _string(messageJson['role'], '$messagePath.role'),
                '$messagePath.role',
              ),
              status: _enumByName(
                MessageStatus.values,
                _string(messageJson['status'], '$messagePath.status'),
                '$messagePath.status',
              ),
              content: _string(messageJson['content'], '$messagePath.content'),
              reasoning: _nullableString(
                messageJson['reasoning'],
                '$messagePath.reasoning',
              ),
              providerTranscriptJson: providerTranscript,
              toolCalls: List<ToolCall>.unmodifiable(calls),
              toolResults: List<ToolResult>.unmodifiable(results),
              createdAt: _date(
                messageJson['createdAt'],
                '$messagePath.createdAt',
              ),
              updatedAt: _date(
                messageJson['updatedAt'],
                '$messagePath.updatedAt',
              ),
            ),
            imageAttachments: List<BackupAttachment>.unmodifiable(
              imageAttachments,
            ),
            documents: List<_ParsedDocument>.unmodifiable(documents),
          ),
        );
      }
      for (final result in conversationResults) {
        if (!conversationCallIds.contains(result.toolCallId)) {
          throw FormatException(
            'Tool result ${result.id} references unknown tool call '
            '${result.toolCallId}.',
          );
        }
      }
      conversations.add(
        _ParsedConversation(
          conversation: conversation,
          messages: List<_ParsedMessage>.unmodifiable(messages),
        ),
      );
    }

    return _ParsedBackup(
      profiles: List<BackupServerProfile>.unmodifiable(profiles),
      conversations: List<_ParsedConversation>.unmodifiable(conversations),
      messageCount: messageCount,
      attachmentCount: attachmentCount,
    );
  }

  static void _validateServerProfileMappings(
    _ParsedBackup parsed,
    Map<String, String> serverProfileMappings,
  ) {
    final usedProfileIds = parsed.conversations
        .map((conversation) => conversation.conversation.serverProfileId)
        .toSet();
    final missingProfiles =
        usedProfileIds
            .where(
              (id) =>
                  serverProfileMappings[id] == null ||
                  serverProfileMappings[id]!.trim().isEmpty,
            )
            .toList()
          ..sort();
    if (missingProfiles.isNotEmpty) {
      throw FormatException(
        'Missing server profile mapping for: ${missingProfiles.join(', ')}.',
      );
    }
  }

  Future<Object?> _cleanupPreparedAttachments(
    List<String> writtenReferences,
    BackupAttachmentCleanup deleteAttachment,
  ) async {
    Object? cleanupError;
    for (final reference in writtenReferences.reversed) {
      try {
        if (!await _store.isAttachmentReferenceInUse(reference)) {
          await deleteAttachment(reference);
        }
      } on Object catch (error) {
        cleanupError ??= error;
      }
    }
    return cleanupError;
  }

  Future<String> _writeImportedAttachment({
    required BackupAttachment attachment,
    required String conversationId,
    required BackupAttachmentWriter writeAttachment,
    required Set<String> uniqueWrittenReferences,
    required List<String> writtenReferences,
  }) async {
    final reference = await writeAttachment(attachment, conversationId);
    if (reference.trim().isEmpty) {
      throw const FormatException(
        'Attachment writer returned an empty reference.',
      );
    }
    if (!uniqueWrittenReferences.add(reference)) {
      throw const FormatException(
        'Attachment writer must create a distinct stored reference for each '
        'imported attachment.',
      );
    }
    if (await _store.isAttachmentReferenceInUse(reference)) {
      throw const FormatException(
        'Attachment writer returned a reference already used by stored history.',
      );
    }
    writtenReferences.add(reference);
    return reference;
  }

  Future<ConversationThread> _restoreConversation({
    required _ParsedConversation source,
    required String conversationId,
    required String serverProfileId,
    required Map<String, String> messageIds,
    required Map<String, String> toolCallIds,
    required Map<String, String> toolResultIds,
    required Map<String, String> documentIds,
    required BackupAttachmentWriter writeAttachment,
    required Set<String> uniqueWrittenReferences,
    required List<String> writtenReferences,
    String? title,
    bool? isRenamed,
  }) async {
    final originalConversation = source.conversation;
    final conversation = Conversation(
      id: conversationId,
      serverProfileId: serverProfileId,
      title: title ?? originalConversation.title,
      selectedModel: originalConversation.selectedModel,
      systemPrompt: originalConversation.systemPrompt,
      createdAt: originalConversation.createdAt,
      updatedAt: originalConversation.updatedAt,
      generationOptions: originalConversation.generationOptions,
      isPinned: originalConversation.isPinned,
      isArchived: originalConversation.isArchived,
      isRenamed: isRenamed ?? originalConversation.isRenamed,
    );
    final messages = <Message>[];
    for (final parsedMessage in source.messages) {
      final original = parsedMessage.message;
      final restoredImages = <String>[];
      for (final attachment in parsedMessage.imageAttachments) {
        restoredImages.add(
          await _writeImportedAttachment(
            attachment: attachment,
            conversationId: conversationId,
            writeAttachment: writeAttachment,
            uniqueWrittenReferences: uniqueWrittenReferences,
            writtenReferences: writtenReferences,
          ),
        );
      }
      final restoredDocuments = <DocumentAttachment>[];
      for (final document in parsedMessage.documents) {
        final reference = await _writeImportedAttachment(
          attachment: document.attachment,
          conversationId: conversationId,
          writeAttachment: writeAttachment,
          uniqueWrittenReferences: uniqueWrittenReferences,
          writtenReferences: writtenReferences,
        );
        restoredDocuments.add(
          DocumentAttachment(
            id: documentIds[document.id]!,
            name: document.name,
            mimeType: document.mimeType,
            reference: reference,
            text: document.text,
          ),
        );
      }
      messages.add(
        Message(
          id: messageIds[original.id]!,
          conversationId: conversationId,
          position: original.position,
          role: original.role,
          status: original.status,
          content: original.content,
          reasoning: original.reasoning,
          providerTranscriptJson: original.providerTranscriptJson,
          imageReferences: List<String>.unmodifiable(restoredImages),
          documents: List<DocumentAttachment>.unmodifiable(restoredDocuments),
          toolCalls: List<ToolCall>.unmodifiable(
            original.toolCalls.map(
              (call) => ToolCall(
                id: toolCallIds[call.id]!,
                name: call.name,
                arguments: call.arguments,
              ),
            ),
          ),
          toolResults: List<ToolResult>.unmodifiable(
            original.toolResults.map(
              (result) => ToolResult(
                id: toolResultIds[result.id]!,
                toolCallId: toolCallIds[result.toolCallId]!,
                content: result.content,
                isError: result.isError,
              ),
            ),
          ),
          createdAt: original.createdAt,
          updatedAt: original.updatedAt,
        ),
      );
    }
    return ConversationThread(
      conversation: conversation,
      messages: List<Message>.unmodifiable(messages),
    );
  }

  BackupAttachment _parseAttachment(Map<String, Object?> json, String path) {
    final name = _nonEmptyString(json['name'], '$path.name');
    if (!_isSafeFileName(name)) {
      throw FormatException('$path.name must be a plain filename.');
    }
    final encoded = _string(json['base64'], '$path.base64');
    if (_maximumDecodedLength(encoded) > limits.maxAttachmentBytes) {
      throw FormatException(
        '$path exceeds the ${limits.maxAttachmentBytes} byte attachment limit.',
      );
    }
    final List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw FormatException('$path.base64 is invalid.');
    }
    if (bytes.length > limits.maxAttachmentBytes) {
      throw FormatException(
        '$path exceeds the ${limits.maxAttachmentBytes} byte attachment limit.',
      );
    }
    return BackupAttachment(sourceName: name, bytes: bytes);
  }

  static void _validateExportDocument(
    DocumentAttachment document,
    String messageId,
  ) {
    if (document.id.trim().isEmpty) {
      throw StateError('Message $messageId has a document with no ID.');
    }
    if (!_isSafeFileName(document.name)) {
      throw StateError(
        'Message $messageId has a document without a plain filename.',
      );
    }
    if (!_supportedDocumentMimeTypes.contains(document.mimeType)) {
      throw StateError(
        'Message $messageId has an unsupported document MIME type.',
      );
    }
    if (document.reference.trim().isEmpty) {
      throw StateError(
        'Message $messageId has a document with no stored reference.',
      );
    }
    if (utf8.encode(document.text).length >
        DocumentAttachment.maxExtractedTextBytes) {
      throw StateError(
        'Message $messageId has document text exceeding the '
        '${DocumentAttachment.maxExtractedTextBytes} byte limit.',
      );
    }
  }

  static void _validateProviderTranscript(String source, String path) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException {
      throw FormatException('$path is not valid JSON.');
    }
    if (decoded is! List || decoded.isEmpty) {
      throw FormatException('$path must be a non-empty JSON array.');
    }

    final toolCallIds = <String>{};
    final toolResultCallIds = <String>[];
    for (var index = 0; index < decoded.length; index++) {
      final messagePath = '$path[$index]';
      final message = _object(decoded[index], messagePath);
      final role = _string(message['role'], '$messagePath.role');
      if (!const <String>{
        'system',
        'user',
        'assistant',
        'tool',
      }.contains(role)) {
        throw FormatException('$messagePath.role has unknown value $role.');
      }
      _string(message['content'], '$messagePath.content');
      if (message.containsKey('thinking')) {
        _string(message['thinking'], '$messagePath.thinking');
      }
      if (message.containsKey('images')) {
        final images = _array(message['images'], '$messagePath.images');
        for (var imageIndex = 0; imageIndex < images.length; imageIndex++) {
          _string(images[imageIndex], '$messagePath.images[$imageIndex]');
        }
      }

      if (message.containsKey('tool_calls')) {
        final calls = _array(message['tool_calls'], '$messagePath.tool_calls');
        for (var callIndex = 0; callIndex < calls.length; callIndex++) {
          final callPath = '$messagePath.tool_calls[$callIndex]';
          final call = _object(calls[callIndex], callPath);
          final callId = _nonEmptyString(call['id'], '$callPath.id');
          if (!toolCallIds.add(callId)) {
            throw FormatException('$callPath.id duplicates tool call $callId.');
          }
          if (call.containsKey('index')) {
            _integer(call['index'], '$callPath.index');
          }
          final function = _object(call['function'], '$callPath.function');
          _nonEmptyString(function['name'], '$callPath.function.name');
          _object(function['arguments'], '$callPath.function.arguments');
          if (function.containsKey('index')) {
            _integer(function['index'], '$callPath.function.index');
          }
          if (function.containsKey('description')) {
            _string(function['description'], '$callPath.function.description');
          }
        }
      }

      if (role == 'tool') {
        toolResultCallIds.add(
          _nonEmptyString(message['tool_call_id'], '$messagePath.tool_call_id'),
        );
        _nonEmptyString(message['tool_name'], '$messagePath.tool_name');
      } else {
        if (message.containsKey('tool_call_id')) {
          _string(message['tool_call_id'], '$messagePath.tool_call_id');
        }
        if (message.containsKey('tool_name')) {
          _string(message['tool_name'], '$messagePath.tool_name');
        }
      }
    }
    for (final callId in toolResultCallIds) {
      if (!toolCallIds.contains(callId)) {
        throw FormatException(
          '$path contains a tool result for unknown tool call $callId.',
        );
      }
    }
  }

  void _validateLimits() {
    if (limits.maxJsonBytes < 1 ||
        limits.maxAttachmentBytes < 1 ||
        limits.maxProfiles < 1 ||
        limits.maxConversations < 1 ||
        limits.maxMessages < 1 ||
        limits.maxAttachments < 1) {
      throw StateError('All chat backup limits must be positive.');
    }
  }

  static void _validateProfile(
    BackupServerProfile profile,
    Set<String> ids, {
    bool malformedInput = false,
  }) {
    Never reject(String message) {
      if (malformedInput) throw FormatException(message);
      throw ArgumentError(message);
    }

    if (profile.id.trim().isEmpty || !ids.add(profile.id)) {
      reject('Server profile IDs must be non-empty and unique.');
    }
    if (profile.name.trim().isEmpty) {
      reject('Server profile names must not be empty.');
    }
    if (profile.protocol != 'ollama' &&
        profile.protocol != 'openAiCompatible') {
      reject('Unknown server protocol ${profile.protocol}.');
    }
    final uri = Uri.tryParse(profile.baseUrl);
    if (uri == null ||
        !uri.hasAuthority ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      reject('Server profile base URL must be an HTTP or HTTPS URL.');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      reject(
        'Server profile base URL must not contain credentials, a query, or '
        'a fragment.',
      );
    }
  }

  static Map<String, Object?> _object(Object? value, String path) {
    if (value is! Map) throw FormatException('$path must be a JSON object.');
    return Map<String, Object?>.from(value);
  }

  static List<Object?> _array(Object? value, String path) {
    if (value is! List) throw FormatException('$path must be a JSON array.');
    return List<Object?>.from(value);
  }

  static String _string(Object? value, String path) {
    if (value is! String) throw FormatException('$path must be a string.');
    return value;
  }

  static String _nonEmptyString(Object? value, String path) {
    final text = _string(value, path);
    if (text.trim().isEmpty) {
      throw FormatException('$path must not be empty.');
    }
    return text;
  }

  static String? _nullableString(Object? value, String path) {
    if (value == null) return null;
    return _string(value, path);
  }

  static int _integer(Object? value, String path) {
    if (value is int) return value;
    throw FormatException('$path must be an integer.');
  }

  static bool _boolean(Object? value, String path) {
    if (value is bool) return value;
    throw FormatException('$path must be a boolean.');
  }

  static DateTime _date(Object? value, String path) {
    final text = _string(value, path);
    final date = DateTime.tryParse(text);
    if (date == null) throw FormatException('$path must be an ISO-8601 date.');
    return date.toUtc();
  }

  static T _enumByName<T extends Enum>(
    List<T> values,
    String name,
    String path,
  ) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    throw FormatException('$path has unknown value $name.');
  }

  static int _maximumDecodedLength(String encoded) {
    if (encoded.isEmpty) return 0;
    final padding = encoded.endsWith('==')
        ? 2
        : encoded.endsWith('=')
        ? 1
        : 0;
    return ((encoded.length + 3) ~/ 4) * 3 - padding;
  }

  static bool _isSafeFileName(String name) =>
      name.length <= 255 &&
      name != '.' &&
      name != '..' &&
      !name.contains('/') &&
      !name.contains('\\') &&
      !name.contains(':') &&
      !name.contains('\u0000');

  static String _safeSourceName(String reference) {
    final normalized = reference.replaceAll('\\', '/');
    final rawName = normalized.split('/').last;
    final sanitized = rawName
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')
        .replaceAll(RegExp(r'^\.+$'), 'image');
    if (sanitized.isEmpty) return 'image';
    return sanitized.length <= 255 ? sanitized : sanitized.substring(0, 255);
  }

  static String _escapeHeading(String value) =>
      value.replaceAll('\\', '\\\\').replaceAll('#', '\\#');

  static String _roleLabel(MessageRole role) => switch (role) {
    MessageRole.system => 'System',
    MessageRole.user => 'You',
    MessageRole.assistant => 'Assistant',
    MessageRole.tool => 'Tool',
  };

  static String _indent(String text) =>
      text.split('\n').map((line) => '    $line').join('\n');

  static const _supportedDocumentMimeTypes = <String>{
    'application/pdf',
    'text/plain',
    'text/markdown',
  };
}

final class _ParsedBackup {
  const _ParsedBackup({
    required this.profiles,
    required this.conversations,
    required this.messageCount,
    required this.attachmentCount,
  });

  final List<BackupServerProfile> profiles;
  final List<_ParsedConversation> conversations;
  final int messageCount;
  final int attachmentCount;
}

final class _ParsedConversation {
  const _ParsedConversation({
    required this.conversation,
    required this.messages,
  });

  final Conversation conversation;
  final List<_ParsedMessage> messages;
}

final class _ParsedMessage {
  const _ParsedMessage({
    required this.message,
    required this.imageAttachments,
    required this.documents,
  });

  final Message message;
  final List<BackupAttachment> imageAttachments;
  final List<_ParsedDocument> documents;
}

final class _ParsedDocument {
  const _ParsedDocument({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.text,
    required this.attachment,
  });

  final String id;
  final String name;
  final String mimeType;
  final String text;
  final BackupAttachment attachment;
}
