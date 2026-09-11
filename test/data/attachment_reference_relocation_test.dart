import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/attachment_reference_codec.dart';
import 'package:mobollama/data/chat_backup.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/document_attachment.dart';
import 'package:mobollama/domain/message.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' as sqflite;

void main() {
  setUpAll(sqflite.sqfliteFfiInit);

  test('attachments and drafts survive an iOS container relocation', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'mobilellama-container-relocation-',
    );
    addTearDown(() async {
      if (await temporary.exists()) await temporary.delete(recursive: true);
    });
    final databasePath = path.join(temporary.path, 'chat.sqlite');
    final oldRoot = Directory(
      path.join(temporary.path, 'old-container', 'Documents', 'chat-images'),
    );
    final oldConversation = Directory(
      path.join(oldRoot.path, 'conversation-files'),
    );
    await oldConversation.create(recursive: true);
    final oldImage = await File(path.join(oldConversation.path, 'photo.png'))
        .writeAsBytes(<int>[1, 2, 3, 4]);
    final oldDocument = await File(path.join(oldConversation.path, 'notes.txt'))
        .writeAsString('Sent document bytes');
    final oldDraftImage = await File(
      path.join(oldConversation.path, 'draft.png'),
    ).writeAsBytes(<int>[5, 6, 7]);
    final oldDraftDocument = await File(
      path.join(oldConversation.path, 'draft.md'),
    ).writeAsString('# Draft document');

    var database = await sqflite.databaseFactoryFfiNoIsolate.openDatabase(
      databasePath,
      options: sqflite.OpenDatabaseOptions(singleInstance: false),
    );
    var store = ConversationStore(SqfliteDatabaseAdapter(database));
    await store.migrate(fromVersion: 0, legacyServerProfileId: 'home');
    await store.createConversation(
      id: 'conversation-1',
      serverProfileId: 'home',
      selectedModel: 'model',
      systemPrompt: '',
    );
    await store.appendMessage(
      id: 'legacy-message',
      conversationId: 'conversation-1',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Read these files.',
      imageReferences: <String>[oldImage.path],
      documents: <DocumentAttachment>[
        DocumentAttachment(
          id: 'legacy-document',
          name: 'notes.txt',
          mimeType: 'text/plain',
          reference: oldDocument.path,
          text: 'Sent document bytes',
        ),
      ],
    );
    await store.saveDrafts(<String, Map<String, Object?>>{
      'new:home': <String, Object?>{
        'text': 'Unsent draft',
        'image': oldDraftImage.path,
        'documents': <Map<String, Object?>>[
          DocumentAttachment(
            id: 'draft-document',
            name: 'draft.md',
            mimeType: 'text/markdown',
            reference: oldDraftDocument.path,
            text: '# Draft document',
          ).toJson(),
        ],
        'reservedId': 'reserved-conversation-id',
      },
    });
    await database.close();

    final newRoot = Directory(
      path.join(temporary.path, 'new-container', 'Documents', 'chat-images'),
    );
    await newRoot.parent.create(recursive: true);
    await oldRoot.rename(newRoot.path);
    final codec = RootedAttachmentReferenceCodec(newRoot.path);
    database = await sqflite.databaseFactoryFfiNoIsolate.openDatabase(
      databasePath,
      options: sqflite.OpenDatabaseOptions(singleInstance: false),
    );
    addTearDown(database.close);
    store = ConversationStore(
      SqfliteDatabaseAdapter(database),
      referenceCodec: codec,
    );
    await store.migrate(
      fromVersion: ConversationStore.schemaVersion,
      legacyServerProfileId: 'home',
    );

    final thread = (await store.openConversation(
      serverProfileId: 'home',
      id: 'conversation-1',
    ))!;
    final message = thread.messages.single;
    final expectedImage = path.join(
      newRoot.path,
      'conversation-files',
      'photo.png',
    );
    final expectedDocument = path.join(
      newRoot.path,
      'conversation-files',
      'notes.txt',
    );
    expect(message.imageReferences.single, expectedImage);
    expect(message.documents.single.reference, expectedDocument);
    expect(await File(message.imageReferences.single).readAsBytes(), <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(
      await File(message.documents.single.reference).readAsString(),
      'Sent document bytes',
    );
    expect(await store.isAttachmentReferenceInUse(expectedImage), isTrue);
    expect(await store.isAttachmentReferenceInUse(expectedDocument), isTrue);

    final drafts = await store.loadDrafts();
    final draft = drafts['new:home']!;
    final draftImage = draft['image']! as String;
    final draftDocument = DocumentAttachment.fromJson(
      Map<String, Object?>.from((draft['documents']! as List).single as Map),
    );
    expect(
      draftImage,
      path.join(newRoot.path, 'conversation-files', 'draft.png'),
    );
    expect(
      draftDocument.reference,
      path.join(newRoot.path, 'conversation-files', 'draft.md'),
    );
    expect(draft['reservedId'], 'reserved-conversation-id');
    expect(await File(draftImage).readAsBytes(), <int>[5, 6, 7]);
    expect(
      await File(draftDocument.reference).readAsString(),
      '# Draft document',
    );

    final backup = await ChatBackup(store).exportJson(
      serverProfiles: const <BackupServerProfile>[
        BackupServerProfile(
          id: 'home',
          name: 'Home',
          protocol: 'ollama',
          baseUrl: 'https://home.test',
        ),
      ],
      readAttachment: (reference) => File(reference).readAsBytes(),
    );
    expect(ChatBackup(store).inspectJson(backup).attachmentCount, 2);
    expect(backup, isNot(contains(oldRoot.path)));
    expect(backup, isNot(contains(newRoot.path)));

    final importedRoot = Directory(
      path.join(temporary.path, 'import-container', 'Documents', 'chat-images'),
    );
    await importedRoot.create(recursive: true);
    final importedDatabase = await sqflite.databaseFactoryFfiNoIsolate
        .openDatabase(
          path.join(temporary.path, 'import.sqlite'),
          options: sqflite.OpenDatabaseOptions(singleInstance: false),
        );
    addTearDown(importedDatabase.close);
    final importedStore = ConversationStore(
      SqfliteDatabaseAdapter(importedDatabase),
      referenceCodec: RootedAttachmentReferenceCodec(importedRoot.path),
    );
    await importedStore.migrate(fromVersion: 0, legacyServerProfileId: 'home');
    var importedId = 0;
    final importedResult = await ChatBackup(importedStore).importJson(
      json: backup,
      serverProfileMappings: const <String, String>{'home': 'home'},
      allocateId: () => 'imported-${++importedId}',
      writeAttachment: (attachment, conversationId) async {
        final directory = Directory(
          path.join(importedRoot.path, conversationId),
        );
        await directory.create(recursive: true);
        final file = File(path.join(directory.path, attachment.sourceName));
        await file.writeAsBytes(attachment.bytes);
        return file.path;
      },
      deleteAttachment: (reference) => File(reference).delete(),
    );
    expect(importedResult.conversations, 1);
    final importedConversation =
        (await importedStore.listAllConversations()).single;
    final importedThread = (await importedStore.openConversation(
      serverProfileId: 'home',
      id: importedConversation.id,
    ))!;
    expect(
      await File(importedThread.messages.single.imageReferences.single)
          .readAsBytes(),
      <int>[1, 2, 3, 4],
    );
    expect(
      await File(importedThread.messages.single.documents.single.reference)
          .readAsString(),
      'Sent document bytes',
    );
    final importedStoredReference =
        (await importedDatabase.rawQuery(
              'SELECT reference FROM message_images LIMIT 1',
            )).single['reference']!
            as String;
    expect(path.isAbsolute(importedStoredReference), isFalse);

    final currentImage = await File(
      path.join(newRoot.path, 'conversation-files', 'current.png'),
    ).writeAsBytes(<int>[8, 9]);
    final currentDocument = await File(
      path.join(newRoot.path, 'conversation-files', 'current.txt'),
    ).writeAsString('Current document');
    await store.appendMessage(
      id: 'current-message',
      conversationId: 'conversation-1',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'New files.',
      imageReferences: <String>[currentImage.path],
      documents: <DocumentAttachment>[
        DocumentAttachment(
          id: 'current-document',
          name: 'current.txt',
          mimeType: 'text/plain',
          reference: currentDocument.path,
          text: 'Current document',
        ),
      ],
    );
    await store.saveDrafts(<String, Map<String, Object?>>{
      'new:home': <String, Object?>{
        ...draft,
        'image': currentImage.path,
        'documents': <Map<String, Object?>>[
          draftDocument.copyWith(reference: currentDocument.path).toJson(),
        ],
      },
    });

    final storedImage =
        (await database.rawQuery(
              'SELECT reference FROM message_images WHERE message_id = ?',
              <Object?>['current-message'],
            )).single['reference']!
            as String;
    final storedDocuments = jsonDecode(
      (await database.rawQuery(
            'SELECT documents_json FROM messages WHERE id = ?',
            <Object?>['current-message'],
          )).single['documents_json']!
          as String,
    ) as List;
    final storedDraft = jsonDecode(
      (await database.rawQuery(
            'SELECT data_json FROM chat_drafts WHERE scope = ?',
            <Object?>['new:home'],
          )).single['data_json']!
          as String,
    ) as Map<String, dynamic>;
    expect(path.isAbsolute(storedImage), isFalse);
    expect(storedImage, path.join('conversation-files', 'current.png'));
    expect(
      path.isAbsolute((storedDocuments.single as Map)['reference'] as String),
      isFalse,
    );
    expect(path.isAbsolute(storedDraft['image'] as String), isFalse);
    expect(
      path.isAbsolute(
        ((storedDraft['documents'] as List).single as Map)['reference']
            as String,
      ),
      isFalse,
    );
    expect(storedDraft['reservedId'], 'reserved-conversation-id');

    expect(() => codec.decode('../outside.png'), throwsFormatException);
    expect(
      () => codec.decode('conversation-files/../outside.png'),
      throwsFormatException,
    );
    expect(
      () => codec.decode(path.join(temporary.path, 'foreign.png')),
      throwsFormatException,
    );
    final outside = await File(path.join(temporary.path, 'foreign.png'))
        .writeAsBytes(<int>[10]);
    await expectLater(
      store.appendMessage(
        id: 'outside-message',
        conversationId: 'conversation-1',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Invalid file.',
        imageReferences: <String>[outside.path],
      ),
      throwsFormatException,
    );
    expect(
      await database.rawQuery('SELECT id FROM messages WHERE id = ?', <Object?>[
        'outside-message',
      ]),
      isEmpty,
    );
  });
}
