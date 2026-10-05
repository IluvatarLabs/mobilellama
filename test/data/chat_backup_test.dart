import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/chat_backup.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/document_attachment.dart';
import 'package:mobollama/domain/generation_options.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/tool_call.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite;

void main() {
  setUpAll(sqflite.sqfliteFfiInit);

  test(
    'portable JSON round-trips complete persisted history additively',
    () async {
      final source = await BackupStoreFixture.open();
      final destination = await BackupStoreFixture.open();
      final files = await Directory.systemTemp.createTemp(
        'mobilellama-backup-test-',
      );
      addTearDown(() async {
        await source.close();
        await destination.close();
        await files.delete(recursive: true);
      });
      final sourceImage = File('${files.path}/source-image.png');
      final sourceDocument = File('${files.path}/evidence.md');
      const imageBytes = <int>[0, 1, 2, 3, 254, 255];
      final documentBytes = utf8.encode('# Evidence\nPrimary source text.');
      await sourceImage.writeAsBytes(imageBytes);
      await sourceDocument.writeAsBytes(documentBytes);
      await _seedPopulatedConversation(
        source.store,
        sourceImage.path,
        sourceDocument.path,
      );
      await _seedExistingConversation(destination.store);

      final backup = ChatBackup(source.store);
      final json = await backup.exportJson(
        serverProfiles: const <BackupServerProfile>[
          BackupServerProfile(
            id: 'source-profile',
            name: 'Home server',
            protocol: 'ollama',
            baseUrl: 'https://ollama.example',
          ),
        ],
        readAttachment: (reference) => File(reference).readAsBytes(),
      );
      final decoded = Map<String, Object?>.from(jsonDecode(json) as Map);
      expect(decoded, isNot(contains('apiKey')));
      final conversationJson = Map<String, Object?>.from(
        (decoded['conversations'] as List).single as Map,
      );
      final messageJson = Map<String, Object?>.from(
        (conversationJson['messages'] as List).first as Map,
      );
      final encodedImage = Map<String, Object?>.from(
        (messageJson['images'] as List).first as Map,
      );
      expect(encodedImage['name'], 'source-image.png');
      expect(encodedImage, isNot(contains('reference')));
      final encodedDocument = Map<String, Object?>.from(
        (messageJson['documents'] as List).single as Map,
      );
      expect(encodedDocument['id'], 'source-document');
      expect(encodedDocument['name'], 'evidence.md');
      expect(encodedDocument['mimeType'], 'text/markdown');
      expect(encodedDocument['text'], '# Evidence\nPrimary source text.');
      expect(base64Decode(encodedDocument['base64']! as String), documentBytes);
      expect(encodedDocument, isNot(contains('reference')));

      final inspection = backup.inspectJson(json);
      expect(inspection.version, 2);
      expect(inspection.profiles.single.id, 'source-profile');
      expect(inspection.conversationCount, 1);
      expect(inspection.messageCount, 2);
      expect(inspection.attachmentCount, 2);

      var nextId = 0;
      final restoredRoot = Directory('${files.path}/restored');
      final result = await ChatBackup(destination.store).importJson(
        json: json,
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => 'restored-${++nextId}',
        writeAttachment: (attachment, conversationId) async {
          final directory = Directory('${restoredRoot.path}/$conversationId');
          await directory.create(recursive: true);
          final file = File('${directory.path}/${attachment.sourceName}');
          await file.writeAsBytes(attachment.bytes);
          return file.path;
        },
        deleteAttachment: (reference) => File(reference).delete(),
      );

      expect(result.conversations, 1);
      expect(result.messages, 2);
      expect(result.attachments, 2);
      final existing = await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'existing-conversation',
      );
      expect(existing!.messages.single.content, 'Existing history');

      final imported = await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'restored-1',
      );
      expect(imported, isNotNull);
      expect(imported!.conversation.title, 'Explicit export title');
      expect(imported.conversation.isPinned, isTrue);
      expect(imported.conversation.isArchived, isTrue);
      expect(imported.conversation.isRenamed, isTrue);
      expect(imported.conversation.selectedModel, 'qwen3:8b');
      expect(imported.conversation.systemPrompt, 'Cite primary sources.');
      expect(imported.conversation.generationOptions.temperature, 0.25);
      expect(imported.conversation.generationOptions.contextSize, 32768);
      expect(imported.messages.map((message) => message.role), <MessageRole>[
        MessageRole.user,
        MessageRole.assistant,
      ]);
      expect(imported.messages.first.content, 'Show me the evidence.');
      expect(imported.messages.first.imageReferences, hasLength(1));
      expect(
        imported.messages.first.imageReferences.single,
        contains('/restored-1/'),
      );
      expect(
        await File(imported.messages.first.imageReferences.single)
            .readAsBytes(),
        imageBytes,
      );
      final importedDocument = imported.messages.first.documents.single;
      expect(importedDocument.id, 'restored-3');
      expect(importedDocument.name, 'evidence.md');
      expect(importedDocument.mimeType, 'text/markdown');
      expect(importedDocument.text, '# Evidence\nPrimary source text.');
      expect(importedDocument.reference, contains('/restored-1/'));
      expect(
        await File(importedDocument.reference).readAsBytes(),
        documentBytes,
      );
      final assistant = imported.messages.last;
      expect(assistant.reasoning, 'Checked the stored evidence.');
      expect(jsonDecode(assistant.providerTranscriptJson!), <Object?>[
        <String, Object?>{'role': 'assistant', 'content': 'Answer'},
      ]);
      expect(assistant.toolCalls.single.id, 'restored-5');
      expect(assistant.toolCalls.single.name, 'web_search');
      expect(assistant.toolCalls.single.arguments, <String, Object?>{
        'query': 'evidence',
      });
      expect(assistant.toolResults.single.id, 'restored-6');
      expect(assistant.toolResults.single.toolCallId, 'restored-5');
      expect(assistant.toolResults.single.content, 'Primary source');

      final markdown = await backup.exportConversationMarkdown(
        serverProfileId: 'source-profile',
        conversationId: 'source-conversation',
      );
      expect(markdown, contains('# Explicit export title'));
      expect(markdown, contains('## You'));
      expect(markdown, contains('Show me the evidence.'));
      expect(markdown, contains('### Reasoning'));
      expect(markdown, contains('### Tool call: web_search'));
      expect(markdown, contains('_Image attachment: source-image.png_'));
      expect(markdown, contains('### Attached document: evidence.md'));
      expect(markdown, contains('# Evidence\nPrimary source text.'));

      final legacyRoot = Map<String, Object?>.from(jsonDecode(json) as Map);
      final legacyConversations = List<Object?>.from(
        legacyRoot['conversations']! as List,
      );
      final legacyConversation = Map<String, Object?>.from(
        legacyConversations.single as Map,
      );
      final legacyMessages = List<Object?>.from(
        legacyConversation['messages']! as List,
      );
      for (var index = 0; index < legacyMessages.length; index++) {
        legacyMessages[index] = Map<String, Object?>.from(
          legacyMessages[index] as Map,
        )..remove('documents');
      }
      legacyConversation['messages'] = legacyMessages;
      legacyConversations[0] = legacyConversation;
      legacyRoot['conversations'] = legacyConversations;
      final legacyJson = jsonEncode(legacyRoot);
      expect(backup.inspectJson(legacyJson).attachmentCount, 1);
      var legacyId = 0;
      await ChatBackup(destination.store).importJson(
        json: legacyJson,
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => 'legacy-${++legacyId}',
        writeAttachment: (attachment, conversationId) async {
          final directory = Directory('${restoredRoot.path}/$conversationId');
          await directory.create(recursive: true);
          final file = File('${directory.path}/${attachment.sourceName}');
          await file.writeAsBytes(attachment.bytes);
          return file.path;
        },
        deleteAttachment: (reference) => File(reference).delete(),
      );
      final legacyImported = await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'legacy-1',
      );
      expect(legacyImported!.messages.first.documents, isEmpty);
    },
  );

  test('portable export can select conversations by ID', () async {
    final source = await BackupStoreFixture.open();
    addTearDown(source.close);
    for (final id in const <String>['included', 'excluded']) {
      await source.store.createConversation(
        id: id,
        serverProfileId: 'source-profile',
        selectedModel: 'model',
        systemPrompt: '',
      );
    }
    final backup = ChatBackup(source.store);
    const profiles = <BackupServerProfile>[
      BackupServerProfile(
        id: 'source-profile',
        name: 'Source',
        protocol: 'ollama',
        baseUrl: 'https://source.example',
      ),
    ];

    final json = await backup.exportJson(
      serverProfiles: profiles,
      conversationIds: const <String>{'included'},
      readAttachment: (_) async => throw StateError(
        'empty selected conversation has no attachment to read',
      ),
    );
    final root = Map<String, Object?>.from(jsonDecode(json) as Map);
    final conversations = List<Object?>.from(root['conversations']! as List);
    expect(conversations, hasLength(1));
    expect(
      Map<String, Object?>.from(conversations.single as Map)['id'],
      'included',
    );

    var reads = 0;
    await expectLater(
      backup.exportJson(
        serverProfiles: profiles,
        conversationIds: const <String>{'missing'},
        readAttachment: (_) async {
          reads++;
          return const <int>[];
        },
      ),
      throwsArgumentError,
    );
    expect(reads, 0);
  });

  test(
    'synced snapshots replace by ID idempotently and preserve conflict copies',
    () async {
      final source = await BackupStoreFixture.open();
      final destination = await BackupStoreFixture.open();
      final files = await Directory.systemTemp.createTemp(
        'mobilellama-sync-apply-test-',
      );
      addTearDown(() async {
        await source.close();
        await destination.close();
        await files.delete(recursive: true);
      });
      final remoteImage = File('${files.path}/remote.png');
      final remoteDocument = File('${files.path}/remote.md');
      await remoteImage.writeAsBytes(<int>[1, 3, 5]);
      await remoteDocument.writeAsString('Remote document text');
      await _seedPopulatedConversation(
        source.store,
        remoteImage.path,
        remoteDocument.path,
      );
      final json = await ChatBackup(source.store).exportJson(
        serverProfiles: const <BackupServerProfile>[
          BackupServerProfile(
            id: 'source-profile',
            name: 'Source',
            protocol: 'ollama',
            baseUrl: 'https://source.example',
          ),
        ],
        readAttachment: (reference) => File(reference).readAsBytes(),
      );

      final oldImage = File('${files.path}/old.png');
      final oldDocument = File('${files.path}/old.txt');
      await oldImage.writeAsBytes(<int>[2, 4, 6]);
      await oldDocument.writeAsString('Old document');
      await destination.store.createConversation(
        id: 'source-conversation',
        serverProfileId: 'destination-profile',
        selectedModel: 'old-model',
        systemPrompt: '',
      );
      await destination.store.appendMessage(
        id: 'old-local-message',
        conversationId: 'source-conversation',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Old local snapshot',
        imageReferences: <String>[oldImage.path],
        documents: <DocumentAttachment>[
          DocumentAttachment(
            id: 'old-document',
            name: 'old.txt',
            mimeType: 'text/plain',
            reference: oldDocument.path,
            text: 'Old document',
          ),
        ],
      );
      await _seedExistingConversation(destination.store);

      var writes = 0;
      final deleted = <String>[];
      Future<String> writer(
        BackupAttachment attachment,
        String conversationId,
      ) async {
        final directory = Directory('${files.path}/synced/$conversationId');
        await directory.create(recursive: true);
        final file = File(
          '${directory.path}/${++writes}-${attachment.sourceName}',
        );
        await file.writeAsBytes(attachment.bytes);
        return file.path;
      }

      Future<void> deleter(String reference) async {
        deleted.add(reference);
        await File(reference).delete();
      }

      final backup = ChatBackup(destination.store);
      await destination.database.execute('''CREATE TRIGGER reject_sync_apply
        BEFORE INSERT ON sync_receipts WHEN NEW.token = 'sync-failed-receipt'
        BEGIN SELECT RAISE(ABORT, 'forced sync receipt failure'); END''');
      final failedPrepared = <String>[];
      final failedCleaned = <String>[];
      await expectLater(
        backup.applySyncedJson(
          json: json,
          targetConversationId: 'source-conversation',
          receiptToken: 'sync-failed-receipt',
          serverProfileMappings: const <String, String>{
            'source-profile': 'destination-profile',
          },
          allocateId: () =>
              throw StateError('normal sync replacement must preserve IDs'),
          writeAttachment: (attachment, conversationId) async {
            final file = File(
              '${files.path}/failed-${failedPrepared.length}-'
              '${attachment.sourceName}',
            );
            await file.writeAsBytes(attachment.bytes);
            failedPrepared.add(file.path);
            return file.path;
          },
          deleteAttachment: (reference) async {
            failedCleaned.add(reference);
            await File(reference).delete();
          },
        ),
        throwsA(isA<sqflite.DatabaseException>()),
      );
      expect(failedCleaned, failedPrepared.reversed.toList());
      for (final reference in failedPrepared) {
        expect(await File(reference).exists(), isFalse);
      }
      expect(
        await destination.store.hasSyncReceipt('sync-failed-receipt'),
        isFalse,
      );
      expect(
        (await destination.store.openConversation(
          serverProfileId: 'destination-profile',
          id: 'source-conversation',
        ))!.messages.single.content,
        'Old local snapshot',
      );
      expect(await oldImage.exists(), isTrue);
      expect(await oldDocument.exists(), isTrue);
      await destination.database.execute('DROP TRIGGER reject_sync_apply');

      final result = await backup.applySyncedJson(
        json: json,
        targetConversationId: 'source-conversation',
        receiptToken: 'sync-receipt-1',
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () =>
            throw StateError('normal sync replacement must preserve IDs'),
        writeAttachment: writer,
        deleteAttachment: deleter,
      );

      expect(result.conversations, 1);
      expect(result.messages, 2);
      expect(result.attachments, 2);
      final synced = await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'source-conversation',
      );
      expect(synced!.messages.map((message) => message.id), <String>[
        'source-user',
        'source-assistant',
      ]);
      expect(synced.messages.first.documents.single.id, 'source-document');
      expect(synced.messages.last.toolCalls.single.id, 'source-call');
      expect(synced.messages.last.toolResults.single.id, 'source-result');
      expect(synced.messages.last.toolResults.single.toolCallId, 'source-call');
      expect(await oldImage.exists(), isFalse);
      expect(await oldDocument.exists(), isFalse);
      expect(deleted.toSet(), <String>{oldImage.path, oldDocument.path});
      expect(
        (await destination.store.openConversation(
          serverProfileId: 'destination-profile',
          id: 'existing-conversation',
        ))!.messages.single.content,
        'Existing history',
      );

      final writesAfterApply = writes;
      final restartedStore = ConversationStore(
        SqfliteDatabaseAdapter(destination.database),
      );
      await restartedStore.migrate(
        fromVersion: ConversationStore.schemaVersion,
        legacyServerProfileId: 'destination-profile',
      );
      final repeated = await ChatBackup(restartedStore).applySyncedJson(
        json: json,
        targetConversationId: 'source-conversation',
        receiptToken: 'sync-receipt-1',
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => throw StateError('receipt must skip allocation'),
        writeAttachment: (attachment, conversationId) async {
          throw StateError('receipt must skip attachment writes');
        },
        deleteAttachment: (_) async {
          throw StateError('receipt must skip attachment cleanup');
        },
      );
      expect(repeated.conversations, 0);
      expect(writes, writesAfterApply);

      var conflictId = 0;
      final conflict = await backup.applySyncedJson(
        json: json,
        targetConversationId: 'stable-conflict-item-id',
        receiptToken: 'sync-receipt-2',
        asConflictCopy: true,
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => 'conflict-${++conflictId}',
        writeAttachment: writer,
        deleteAttachment: deleter,
      );
      expect(conflict.conversations, 1);
      final conflictThread = await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'stable-conflict-item-id',
      );
      expect(conflictThread!.conversation.title, endsWith(' (conflict copy)'));
      expect(conflictThread.conversation.isRenamed, isTrue);
      expect(conflictThread.messages.first.id, 'conflict-1');
      expect(conflictThread.messages.first.documents.single.id, 'conflict-2');
      expect(conflictThread.messages.last.id, 'conflict-3');
      expect(conflictThread.messages.last.toolCalls.single.id, 'conflict-4');
      expect(conflictThread.messages.last.toolResults.single.id, 'conflict-5');
      expect(
        (await destination.store.openConversation(
          serverProfileId: 'destination-profile',
          id: 'source-conversation',
        ))!.messages.first.id,
        'source-user',
      );

      final writesBeforeCollision = writes;
      await expectLater(
        backup.applySyncedJson(
          json: json,
          targetConversationId: 'stable-conflict-item-id',
          receiptToken: 'sync-receipt-without-target-ownership',
          asConflictCopy: true,
          serverProfileMappings: const <String, String>{
            'source-profile': 'destination-profile',
          },
          allocateId: () => 'unused',
          writeAttachment: writer,
          deleteAttachment: deleter,
        ),
        throwsA(isA<FormatException>()),
      );
      expect(writes, writesBeforeCollision);
    },
  );

  test(
    'synced replacement reports obsolete attachment cleanup after committing',
    () async {
      final source = await BackupStoreFixture.open();
      final destination = await BackupStoreFixture.open();
      final files = await Directory.systemTemp.createTemp(
        'mobilellama-sync-cleanup-warning-test-',
      );
      addTearDown(() async {
        await source.close();
        await destination.close();
        await files.delete(recursive: true);
      });

      await source.store.createConversation(
        id: 'synced-conversation',
        serverProfileId: 'source-profile',
        selectedModel: 'remote-model',
        systemPrompt: '',
      );
      await source.store.appendMessage(
        id: 'remote-message',
        conversationId: 'synced-conversation',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Remote committed content',
      );
      final json = await ChatBackup(source.store).exportJson(
        serverProfiles: const <BackupServerProfile>[
          BackupServerProfile(
            id: 'source-profile',
            name: 'Source',
            protocol: 'ollama',
            baseUrl: 'https://source.example',
          ),
        ],
        readAttachment: (_) async =>
            throw StateError('the remote snapshot has no attachments'),
      );

      final obsoleteImage = File('${files.path}/obsolete.png');
      await obsoleteImage.writeAsBytes(<int>[1, 2, 3]);
      await destination.store.createConversation(
        id: 'synced-conversation',
        serverProfileId: 'destination-profile',
        selectedModel: 'old-model',
        systemPrompt: '',
      );
      await destination.store.appendMessage(
        id: 'old-message',
        conversationId: 'synced-conversation',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Old local content',
        imageReferences: <String>[obsoleteImage.path],
      );

      final result = await ChatBackup(destination.store).applySyncedJson(
        json: json,
        targetConversationId: 'synced-conversation',
        receiptToken: 'cleanup-warning-receipt',
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => throw StateError('IDs must be preserved'),
        writeAttachment: (_, _) async =>
            throw StateError('the remote snapshot has no attachments'),
        deleteAttachment: (_) async =>
            throw StateError('forced obsolete attachment cleanup failure'),
      );

      expect(result.conversations, 1);
      expect(result.messages, 1);
      expect(result.attachments, 0);
      expect(result.cleanupWarning, contains('unused attachment'));
      expect(
        await destination.store.hasSyncReceipt('cleanup-warning-receipt'),
        isTrue,
      );
      final synced = await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'synced-conversation',
      );
      expect(synced!.messages.single.content, 'Remote committed content');
      expect(await obsoleteImage.exists(), isTrue);
    },
  );

  test('synced preserved-ID collision rolls back without a receipt', () async {
    final source = await BackupStoreFixture.open();
    final destination = await BackupStoreFixture.open();
    addTearDown(() async {
      await source.close();
      await destination.close();
    });
    await source.store.createConversation(
      id: 'source-conversation',
      serverProfileId: 'source-profile',
      selectedModel: 'remote-model',
      systemPrompt: '',
    );
    await source.store.appendMessage(
      id: 'remote-message-id',
      conversationId: 'source-conversation',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Remote content',
    );
    for (final id in const <String>['source-conversation', 'unrelated']) {
      await destination.store.createConversation(
        id: id,
        serverProfileId: 'destination-profile',
        selectedModel: 'local-model',
        systemPrompt: '',
      );
    }
    await destination.store.appendMessage(
      id: 'old-target-message',
      conversationId: 'source-conversation',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Target must survive',
    );
    await destination.store.appendMessage(
      id: 'remote-message-id',
      conversationId: 'unrelated',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Unrelated owner',
    );
    final json = await ChatBackup(source.store).exportJson(
      serverProfiles: const <BackupServerProfile>[
        BackupServerProfile(
          id: 'source-profile',
          name: 'Source',
          protocol: 'ollama',
          baseUrl: 'https://source.example',
        ),
      ],
      readAttachment: (_) async => throw StateError('no attachments expected'),
    );

    await expectLater(
      ChatBackup(destination.store).applySyncedJson(
        json: json,
        targetConversationId: 'source-conversation',
        receiptToken: 'collision-receipt',
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => throw StateError('normal sync preserves IDs'),
        writeAttachment: (_, _) async =>
            throw StateError('no attachments expected'),
        deleteAttachment: (_) async {},
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('unrelated conversation'),
        ),
      ),
    );
    expect(
      await destination.store.hasSyncReceipt('collision-receipt'),
      isFalse,
    );
    expect(
      (await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'source-conversation',
      ))!.messages.single.content,
      'Target must survive',
    );
    expect(
      (await destination.store.openConversation(
        serverProfileId: 'destination-profile',
        id: 'unrelated',
      ))!.messages.single.content,
      'Unrelated owner',
    );
  });

  test('invalid backup and missing profile mapping add nothing', () async {
    final source = await BackupStoreFixture.open();
    final destination = await BackupStoreFixture.open();
    final files = await Directory.systemTemp.createTemp(
      'mobilellama-invalid-backup-test-',
    );
    addTearDown(() async {
      await source.close();
      await destination.close();
      await files.delete(recursive: true);
    });
    final sourceImage = File('${files.path}/source.png');
    final sourceDocument = File('${files.path}/evidence.md');
    await sourceImage.writeAsBytes(<int>[1, 2, 3]);
    await sourceDocument.writeAsString('Evidence');
    await _seedPopulatedConversation(
      source.store,
      sourceImage.path,
      sourceDocument.path,
    );
    await _seedExistingConversation(destination.store);
    final sourceBackup = ChatBackup(source.store);
    final validJson = await sourceBackup.exportJson(
      serverProfiles: const <BackupServerProfile>[
        BackupServerProfile(
          id: 'source-profile',
          name: 'Source',
          protocol: 'ollama',
          baseUrl: 'https://source.example',
        ),
      ],
      readAttachment: (reference) => File(reference).readAsBytes(),
    );
    await expectLater(
      sourceBackup.exportJson(
        serverProfiles: const <BackupServerProfile>[
          BackupServerProfile(
            id: 'source-profile',
            name: 'Source',
            protocol: 'ollama',
            baseUrl: 'https://user:secret@source.example',
          ),
        ],
        readAttachment: (_) async => throw StateError(
          'credential validation must precede attachment reads',
        ),
      ),
      throwsArgumentError,
    );
    final destinationBackup = ChatBackup(destination.store);
    var writes = 0;
    Future<String> writer(
      BackupAttachment attachment,
      String conversationId,
    ) async {
      writes++;
      return '${files.path}/unexpected';
    }

    final malformedTranscript = Map<String, Object?>.from(
      jsonDecode(validJson) as Map,
    );
    final transcriptConversations = List<Object?>.from(
      malformedTranscript['conversations']! as List,
    );
    final transcriptConversation = Map<String, Object?>.from(
      transcriptConversations.single as Map,
    );
    final transcriptMessages = List<Object?>.from(
      transcriptConversation['messages']! as List,
    );
    transcriptMessages[1] = Map<String, Object?>.from(
      transcriptMessages[1] as Map,
    )..['providerTranscriptJson'] = '{}';
    transcriptConversation['messages'] = transcriptMessages;
    transcriptConversations[0] = transcriptConversation;
    malformedTranscript['conversations'] = transcriptConversations;
    await expectLater(
      destinationBackup.importJson(
        json: jsonEncode(malformedTranscript),
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => 'unused',
        writeAttachment: writer,
        deleteAttachment: (_) async {},
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('must be a non-empty JSON array'),
        ),
      ),
    );
    expect(writes, 0);

    transcriptMessages[1] =
        Map<String, Object?>.from(transcriptMessages[1] as Map)
          ..['providerTranscriptJson'] = jsonEncode(<Object?>[
            <String, Object?>{
              'role': 'assistant',
              'content': '',
              'tool_calls': <Object?>[
                <String, Object?>{
                  'id': 'provider-call',
                  'function': <String, Object?>{
                    'name': 'web_search',
                    'arguments': <String, Object?>{'query': 'evidence'},
                  },
                },
              ],
            },
            <String, Object?>{
              'role': 'tool',
              'content': 'result',
              'tool_name': 'web_search',
              'tool_call_id': 'missing-call',
            },
          ]);
    transcriptConversation['messages'] = transcriptMessages;
    transcriptConversations[0] = transcriptConversation;
    malformedTranscript['conversations'] = transcriptConversations;
    await expectLater(
      destinationBackup.importJson(
        json: jsonEncode(malformedTranscript),
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => 'unused',
        writeAttachment: writer,
        deleteAttachment: (_) async {},
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('tool result for unknown tool call missing-call'),
        ),
      ),
    );
    expect(writes, 0);

    final unknownVersion = Map<String, Object?>.from(
      jsonDecode(validJson) as Map,
    )..['version'] = 999;
    expect(
      () => destinationBackup.inspectJson(jsonEncode(unknownVersion)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Unsupported MobileLlama backup version 999'),
        ),
      ),
    );

    final malformed = Map<String, Object?>.from(jsonDecode(validJson) as Map);
    final conversations = List<Object?>.from(
      malformed['conversations']! as List,
    );
    final conversation = Map<String, Object?>.from(conversations.single as Map);
    final messages = List<Object?>.from(conversation['messages']! as List);
    final firstMessage = Map<String, Object?>.from(messages.first as Map);
    final documents = List<Object?>.from(firstMessage['documents']! as List);
    final firstDocument = Map<String, Object?>.from(documents.first as Map)
      ..['base64'] = 'not valid base64!';
    documents[0] = firstDocument;
    firstMessage['documents'] = documents;
    messages[0] = firstMessage;
    conversation['messages'] = messages;
    conversations[0] = conversation;
    malformed['conversations'] = conversations;
    await expectLater(
      destinationBackup.importJson(
        json: jsonEncode(malformed),
        serverProfileMappings: const <String, String>{
          'source-profile': 'destination-profile',
        },
        allocateId: () => 'unused',
        writeAttachment: writer,
        deleteAttachment: (_) async {},
      ),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      destinationBackup.importJson(
        json: validJson,
        serverProfileMappings: const <String, String>{},
        allocateId: () => 'unused',
        writeAttachment: writer,
        deleteAttachment: (_) async {},
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Missing server profile mapping for: source-profile'),
        ),
      ),
    );
    expect(writes, 0);
    final all = await destination.store.listAllConversations(
      includeEmpty: true,
    );
    expect(all.map((conversation) => conversation.id), <String>[
      'existing-conversation',
    ]);
  });

  test(
    'database import failure rolls back and cleans prepared attachments',
    () async {
      final source = await BackupStoreFixture.open();
      final destination = await BackupStoreFixture.open();
      final files = await Directory.systemTemp.createTemp(
        'mobilellama-backup-rollback-test-',
      );
      addTearDown(() async {
        await source.close();
        await destination.close();
        await files.delete(recursive: true);
      });
      final sourceImage = File('${files.path}/source.png');
      final sourceDocument = File('${files.path}/evidence.md');
      await sourceImage.writeAsBytes(<int>[4, 5, 6]);
      await sourceDocument.writeAsString('Evidence');
      await _seedPopulatedConversation(
        source.store,
        sourceImage.path,
        sourceDocument.path,
      );
      await _seedExistingConversation(destination.store);
      final json = await ChatBackup(source.store).exportJson(
        serverProfiles: const <BackupServerProfile>[
          BackupServerProfile(
            id: 'source-profile',
            name: 'Source',
            protocol: 'ollama',
            baseUrl: 'https://source.example',
          ),
        ],
        readAttachment: (reference) => File(reference).readAsBytes(),
      );
      await destination.database.execute('''CREATE TRIGGER reject_import
      BEFORE INSERT ON conversations WHEN NEW.id = 'restored-1'
      BEGIN SELECT RAISE(ABORT, 'forced import failure'); END''');
      var nextId = 0;
      final prepared = <String>[];
      final cleaned = <String>[];

      await expectLater(
        ChatBackup(destination.store).importJson(
          json: json,
          serverProfileMappings: const <String, String>{
            'source-profile': 'destination-profile',
          },
          allocateId: () => 'restored-${++nextId}',
          writeAttachment: (attachment, conversationId) async {
            final file = File(
              '${files.path}/$conversationId-${attachment.sourceName}',
            );
            await file.writeAsBytes(attachment.bytes);
            prepared.add(file.path);
            return file.path;
          },
          deleteAttachment: (reference) async {
            cleaned.add(reference);
            await File(reference).delete();
          },
        ),
        throwsA(isA<sqflite.DatabaseException>()),
      );

      expect(prepared, hasLength(2));
      expect(cleaned, prepared.reversed.toList());
      for (final reference in prepared) {
        expect(await File(reference).exists(), isFalse);
      }
      final all = await destination.store.listAllConversations(
        includeEmpty: true,
      );
      expect(all.map((conversation) => conversation.id), <String>[
        'existing-conversation',
      ]);
    },
  );

  test(
    'import never deletes an image path owned by existing history',
    () async {
      final source = await BackupStoreFixture.open();
      final destination = await BackupStoreFixture.open();
      final files = await Directory.systemTemp.createTemp(
        'mobilellama-backup-owned-image-test-',
      );
      addTearDown(() async {
        await source.close();
        await destination.close();
        await files.delete(recursive: true);
      });
      final sourceImage = File('${files.path}/source.png');
      final sourceDocument = File('${files.path}/evidence.md');
      final existingImage = File('${files.path}/existing.png');
      await sourceImage.writeAsBytes(<int>[1, 2, 3]);
      await sourceDocument.writeAsString('Evidence');
      await existingImage.writeAsBytes(<int>[7, 8, 9]);
      await _seedPopulatedConversation(
        source.store,
        sourceImage.path,
        sourceDocument.path,
      );
      await _seedExistingConversation(
        destination.store,
        imageReference: existingImage.path,
      );
      final json = await ChatBackup(source.store).exportJson(
        serverProfiles: const <BackupServerProfile>[
          BackupServerProfile(
            id: 'source-profile',
            name: 'Source',
            protocol: 'ollama',
            baseUrl: 'https://source.example',
          ),
        ],
        readAttachment: (reference) => File(reference).readAsBytes(),
      );
      var nextId = 0;
      var cleanupCalls = 0;

      await expectLater(
        ChatBackup(destination.store).importJson(
          json: json,
          serverProfileMappings: const <String, String>{
            'source-profile': 'destination-profile',
          },
          allocateId: () => 'restored-${++nextId}',
          writeAttachment: (_, _) async => existingImage.path,
          deleteAttachment: (_) async {
            cleanupCalls++;
          },
        ),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('reference already used by stored history'),
          ),
        ),
      );

      expect(cleanupCalls, 0);
      expect(await existingImage.readAsBytes(), <int>[7, 8, 9]);
      final all = await destination.store.listAllConversations(
        includeEmpty: true,
      );
      expect(all.map((conversation) => conversation.id), <String>[
        'existing-conversation',
      ]);
    },
  );
}

Future<void> _seedPopulatedConversation(
  ConversationStore store,
  String imageReference,
  String documentReference,
) async {
  final createdAt = DateTime.utc(2026, 9, 10, 12);
  await store.createConversation(
    id: 'source-conversation',
    serverProfileId: 'source-profile',
    selectedModel: 'qwen3:8b',
    systemPrompt: 'Cite primary sources.',
    generationOptions: const GenerationOptions(
      temperature: 0.25,
      contextSize: 32768,
    ),
    now: createdAt,
  );
  await store.appendMessage(
    id: 'source-user',
    conversationId: 'source-conversation',
    role: MessageRole.user,
    status: MessageStatus.complete,
    content: 'Show me the evidence.',
    imageReferences: <String>[imageReference],
    documents: <DocumentAttachment>[
      DocumentAttachment(
        id: 'source-document',
        name: 'evidence.md',
        mimeType: 'text/markdown',
        reference: documentReference,
        text: await File(documentReference).readAsString(),
      ),
    ],
    now: createdAt.add(const Duration(seconds: 1)),
  );
  await store.appendMessage(
    id: 'source-assistant',
    conversationId: 'source-conversation',
    role: MessageRole.assistant,
    status: MessageStatus.streaming,
    content: 'Here is the evidence.',
    reasoning: 'Checked the stored evidence.',
    toolCalls: const <ToolCall>[
      ToolCall(
        id: 'source-call',
        name: 'web_search',
        arguments: <String, Object?>{'query': 'evidence'},
      ),
    ],
    toolResults: const <ToolResult>[
      ToolResult(
        id: 'source-result',
        toolCallId: 'source-call',
        content: 'Primary source',
      ),
    ],
    now: createdAt.add(const Duration(seconds: 2)),
  );
  final assistant = (await store.openConversation(
    serverProfileId: 'source-profile',
    id: 'source-conversation',
  ))!.messages.last;
  await store.updateMessage(
    assistant.copyWith(
      status: MessageStatus.complete,
      providerTranscriptJson: jsonEncode(<Object?>[
        <String, Object?>{'role': 'assistant', 'content': 'Answer'},
      ]),
    ),
  );
  await store.rename('source-conversation', 'Explicit export title');
  await store.setPinned('source-conversation', true);
  await store.setArchived('source-conversation', true);
}

Future<void> _seedExistingConversation(
  ConversationStore store, {
  String? imageReference,
}) async {
  await store.createConversation(
    id: 'existing-conversation',
    serverProfileId: 'destination-profile',
    selectedModel: 'existing-model',
    systemPrompt: '',
  );
  await store.appendMessage(
    id: 'existing-message',
    conversationId: 'existing-conversation',
    role: MessageRole.user,
    status: MessageStatus.complete,
    content: 'Existing history',
    imageReferences: imageReference == null
        ? const <String>[]
        : <String>[imageReference],
  );
}

final class BackupStoreFixture {
  const BackupStoreFixture(this.database, this.store);

  final sqflite.Database database;
  final ConversationStore store;

  static Future<BackupStoreFixture> open() async {
    final database = await sqflite.databaseFactoryFfiNoIsolate.openDatabase(
      sqflite.inMemoryDatabasePath,
      options: sqflite.OpenDatabaseOptions(singleInstance: false),
    );
    final store = ConversationStore(SqfliteDatabaseAdapter(database));
    await store.migrate(
      fromVersion: 0,
      legacyServerProfileId: 'legacy-profile',
    );
    return BackupStoreFixture(database, store);
  }

  Future<void> close() => database.close();
}
