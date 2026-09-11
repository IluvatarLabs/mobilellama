import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/document_reader.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/domain/generation_options.dart';

import '../support/chat_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('backup import matches servers and adds an unavailable profile without credentials or HTTP acknowledgement', () async {
    final source = ChatFixture();
    await source.open();
    addTearDown(source.close);
    await source.settings.upsertProfile(
      ServerProfile(
        id: 'remote-profile',
        name: 'Private server',
        protocol: ServerProtocol.openAiCompatible,
        baseUrl: 'http://192.168.2.10:8000/v1',
        acknowledgedInsecureOrigin: 'http://192.168.2.10:8000',
      ),
    );
    await source.seed('remote-history', profile: 'remote-profile');
    source.secrets.values['source-secret'] = 'do-not-export-me';
    await source.controller.initialize();
    final backup = await source.controller.exportBackup();
    expect(backup, isNot(contains('do-not-export-me')));
    final target = ChatFixture();
    await target.open();
    addTearDown(target.close);
    await target.seed('existing');
    await target.controller.initialize();
    expect(await target.controller.importBackup(backup), 1);
    expect(target.controller.history, hasLength(2));
    expect(
      target.controller.profiles.where((p) => p.baseUrl == 'https://home.test'),
      hasLength(1),
    );
    final profile = target.controller.profiles.singleWhere(
      (p) => p.name == 'Private server',
    );
    expect(profile.id, isNot('remote-profile'));
    expect(profile.insecureLanAcknowledged, isFalse);
    expect(target.controller.hasServerApiKeyForProfile(profile.id), isFalse);
    expect(target.controller.activeProfileId, 'home');
    final restored = target.controller.history.singleWhere(
      (c) => c.id != 'existing',
    );
    expect(restored.serverProfileId, profile.id);
    await target.controller.openConversation(restored.id);
    expect(target.controller.conversationConnected, isFalse);
    expect(target.controller.messages, hasLength(2));
  });

  test(
    'document survives draft restart, send, edit and portable backup',
    () async {
      final f = ChatFixture();
      final directory = await Directory.systemTemp.createTemp(
        'mobilellama-document-flow-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = await File('${directory.path}/notes.txt')
          .writeAsString('The project deadline is Friday.');
      f.documentReader = DocumentReader(picker: () async => XFile(file.path));
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      expect(f.controller.supportsImages, isFalse);
      await f.controller.pickDocument();
      expect(f.controller.pendingDocuments.single.name, 'notes.txt');
      f.controller.setDraftText('Summarize this.');
      await f.controller.shutdown();
      f.controller.dispose();
      f.createController();
      await f.controller.initialize();
      expect(f.controller.pendingDocuments.single.text, contains('Friday'));
      expect(await f.controller.send(f.controller.draftText), isTrue);
      expect(f.controller.pendingDocuments, isEmpty);
      expect(
        (f.requests.last['messages'] as List).last['content'],
        contains('notes.txt'),
      );
      expect(
        (f.requests.last['messages'] as List).last['content'],
        contains('Friday'),
      );
      final user = f.controller.messages.first;
      expect(user.documents.single.name, 'notes.txt');
      expect(
        await f.controller.editAndResend(user.id, 'What is the deadline?'),
        isTrue,
      );
      expect(
        f.controller.messages.first.documents.single.reference,
        user.documents.single.reference,
      );
      final backup = await f.controller.exportBackup();
      expect(await f.controller.importBackup(backup), 1);
      final copy = f.controller.history.firstWhere(
        (chat) => chat.id != user.conversationId,
      );
      final restored = (await f.store.openConversation(
        serverProfileId: copy.serverProfileId,
        id: copy.id,
      ))!;
      final document = restored.messages.first.documents.single;
      expect(document.reference, isNot(user.documents.single.reference));
      expect(
        utf8.decode(
          base64Decode(await f.images.readAsBase64(document.reference)),
        ),
        'The project deadline is Friday.',
      );
    },
  );

  test(
    'context size slices whole tool turns and notices belong to their chat',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('tools');
      for (final role in [MessageRole.user, MessageRole.assistant]) {
        await f.store.appendMessage(
          id: 'old-${role.name}',
          conversationId: 'tools',
          role: role,
          status: MessageStatus.complete,
          content: List.filled(64, role == MessageRole.user ? 'A' : 'B').join(),
        );
      }
      await f.store.appendMessage(
        id: 'tool-question',
        conversationId: 'tools',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Tool question',
      );
      final answer = await f.store.appendMessage(
        id: 'tool-answer',
        conversationId: 'tools',
        role: MessageRole.assistant,
        status: MessageStatus.complete,
        content: 'Done',
      );
      await f.store.updateMessage(
        answer.copyWith(
          providerTranscriptJson: jsonEncode([
            {
              'role': 'assistant',
              'content': '',
              'tool_calls': [
                {
                  'id': 'wire-call',
                  'type': 'function',
                  'function': {'name': 'web_fetch', 'arguments': {}},
                },
              ],
            },
            {
              'role': 'tool',
              'content': 'Fetched result',
              'tool_call_id': 'wire-call',
            },
            {'role': 'assistant', 'content': 'Done'},
          ]),
        ),
      );
      await f.controller.initialize();
      await f.controller.openConversation('tools');
      await f.controller.updateGenerationOptions(
        const GenerationOptions(contextSize: 256),
      );
      expect(await f.controller.send('Newest question'), isTrue);
      final sent = f.requests.last['messages'] as List;
      expect(sent.where((m) => m['role'] == 'tool'), hasLength(1));
      expect(sent.any((m) => m['tool_calls'] != null), isTrue);
      expect(
        sent.any((m) => (m['content'] as String).contains('AAAA')),
        isFalse,
      );
      expect(
        f.controller.messages.any((m) => m.content.contains('AAAA')),
        isTrue,
      );
      expect(f.controller.contextNotice, isNotNull);
      await f.controller.newConversation();
      expect(f.controller.contextNotice, isNull);
    },
  );

  test(
    'a failed durable draft clear remains visible after a successful answer',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      f.controller.setDraftText('Keep this visible on storage failure');
      await f.controller.flushDrafts();
      await f.database.execute(
        "CREATE TRIGGER reject_draft_delete BEFORE DELETE ON chat_drafts BEGIN SELECT RAISE(ABORT, 'draft disk failure'); END",
      );
      expect(await f.controller.send(f.controller.draftText), isTrue);
      expect(f.controller.messages.last.status, MessageStatus.complete);
      expect(f.controller.errorMessage, contains('draft could not be saved'));
      await f.database.execute('DROP TRIGGER reject_draft_delete');
      await f.controller.flushDrafts();
      expect(f.controller.errorMessage, isNull);
      expect(await f.store.loadDrafts(), isEmpty);
    },
  );

  test(
    'failed draft removal retains the image referenced by durable storage',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      await f.controller.selectModel('gemma3:4b');
      await f.controller.pickImage();
      await f.controller.flushDrafts();
      final image = f.controller.pendingImageReference;
      await f.database.execute(
        "CREATE TRIGGER reject_draft_delete BEFORE DELETE ON chat_drafts BEGIN SELECT RAISE(ABORT, 'draft disk failure'); END",
      );
      await f.controller.removePendingImage();
      expect(f.controller.errorMessage, contains('draft could not be saved'));
      expect((await f.store.loadDrafts())['new:home']?['images'], [image]);
      expect(f.images.deleted, isNot(contains(image)));
      await f.database.execute('DROP TRIGGER reject_draft_delete');
    },
  );

  test('delete all rolls back history and preserves draft files on storage failure', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.seed('existing');
    await f.controller.initialize();
    await f.controller.selectModel('gemma3:4b');
    f.controller.setDraftText('Unsent draft');
    await f.controller.pickImage();
    await f.controller.flushDrafts();
    final before = await f.store.loadDrafts();
    await f.database.execute(
      "CREATE TRIGGER reject_draft_delete BEFORE DELETE ON chat_drafts BEGIN SELECT RAISE(ABORT, 'draft disk failure'); END",
    );
    expect(await f.controller.deleteAllConversations(), isFalse);
    expect(await f.store.loadDrafts(), before);
    expect(await f.store.listAllConversations(), hasLength(1));
    expect(f.controller.draftText, 'Unsent draft');
    expect(f.images.deleted, isEmpty);
    await f.database.execute('DROP TRIGGER reject_draft_delete');
    expect(await f.controller.deleteAllConversations(), isTrue);
    expect(await f.store.loadDrafts(), isEmpty);
    expect(await f.store.listAllConversations(), isEmpty);
    expect(f.images.deleted, contains('existing'));
  });

  test('presets persist and apply only to the selected chat', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.seed('selected');
    await f.seed('other');
    await f.controller.initialize();
    final defaults = f.controller.chatDefaults.systemPrompt;
    final other = await f.store.openConversation(
      serverProfileId: 'home',
      id: 'other',
    );
    expect(
      await f.controller.savePromptPreset(
        name: 'Explain clearly',
        systemPrompt: 'Use plain language.',
        generationOptions: const GenerationOptions(temperature: .3),
      ),
      isTrue,
    );
    final id = f.controller.promptPresets.single.id;
    await f.controller.shutdown();
    f.controller.dispose();
    f.createController();
    await f.controller.initialize();
    expect(f.controller.promptPresets.single.name, 'Explain clearly');
    await f.controller.openConversation('selected');
    expect(await f.controller.applyPromptPreset(id), isTrue);
    expect(f.controller.systemPrompt, 'Use plain language.');
    expect(f.controller.generationOptions.temperature, .3);
    expect(f.controller.chatDefaults.systemPrompt, defaults);
    expect(
      (await f.store.openConversation(
        serverProfileId: 'home',
        id: 'other',
      ))!.conversation.systemPrompt,
      other!.conversation.systemPrompt,
    );
    expect(await f.controller.deletePromptPreset(id), isTrue);
    expect(f.controller.systemPrompt, 'Use plain language.');
    expect(
      await f.controller.savePromptPreset(
        name: ' ',
        systemPrompt: '',
        generationOptions: const GenerationOptions(),
      ),
      isFalse,
    );
  });

  test(
    'compatible images, reasoning and remote activity reach persisted chat',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      expect(
        await f.controller.upsertServerProfile(
          ServerProfile(
            id: 'compatible',
            name: 'Compatible',
            protocol: ServerProtocol.openAiCompatible,
            baseUrl: 'https://compatible.test/v1',
          ),
          makeActive: true,
        ),
        isTrue,
      );
      expect(f.controller.supportsImages, isTrue);
      await f.controller.pickImage();
      expect(await f.controller.send('Describe this image'), isTrue);
      final request = f.requests.last;
      expect((request['headers'] as Map).containsKey('authorization'), isFalse);
      final content = (request['messages'] as List).last['content'] as List;
      expect(content.last['type'], 'image_url');
      expect(content.last['image_url']['url'], startsWith('data:image/'));
      final answer = f.controller.messages.last;
      expect(answer.content, 'An image answer.');
      expect(answer.reasoning, 'Considered the image.');
      expect(answer.toolCalls.single.name, 'browser');
      expect(answer.toolResults.single.content, 'Read the page');
      final restored = await f.store.openConversation(
        serverProfileId: 'compatible',
        id: f.controller.conversation!.id,
      );
      expect(restored!.messages.last.reasoning, answer.reasoning);
      expect(restored.messages.last.toolCalls.single.name, 'browser');
    },
  );

  test(
    'backgrounding retains the active response and durable follow-up draft',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      f.holdResponse = true;
      final response = f.controller.send('A slow request');
      for (
        var attempt = 0;
        attempt < 100 &&
            (!f.controller.isStreaming ||
                f.controller.messages.last.content.isEmpty);
        attempt++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(f.controller.messages.last.content, isNotEmpty);
      f.controller.setDraftText('Follow-up to keep');
      await f.controller.pauseForBackground();
      expect(f.controller.isStreaming, isTrue);
      expect(f.controller.messages.last.status, MessageStatus.streaming);
      f.responseControls.single.complete();
      expect(await response, isTrue);
      expect(f.controller.messages.last.status, MessageStatus.complete);
      expect(f.controller.draftText, 'Follow-up to keep');
      expect(
        (await f.store.loadDrafts())[f.controller.conversation!.id]?['text'],
        'Follow-up to keep',
      );
    },
  );

  test(
    'edit and regenerate send the retained prefix and preserve other chats',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('first');
      await f.seed('other');
      await f.controller.initialize();
      await f.controller.openConversation('first');
      await f.controller.send('Later question to replace');
      expect(
        await f.controller.editAndResend('first-user', 'Corrected question'),
        isTrue,
      );
      final sent = f.requests.last['messages'] as List;
      expect(sent.map((m) => m['content']), [
        'Be clear.',
        'Corrected question',
      ]);
      expect(
        f.controller.messages
            .where((m) => m.role == MessageRole.user)
            .single
            .content,
        'Corrected question',
      );
      final completed = f.controller.messages.last;
      expect(completed.status, MessageStatus.complete);
      expect(await f.controller.regenerateAssistant(completed.id), isTrue);
      expect(f.controller.messages.last.id, isNot(completed.id));
      expect(f.controller.messages.last.status, MessageStatus.complete);
      expect(
        (await f.store.openConversation(
          serverProfileId: 'home',
          id: 'other',
        ))!.messages,
        hasLength(2),
      );
    },
  );

  test('scoped text and image drafts survive restart and clear only after acceptance', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.seed('existing');
    await f.controller.initialize();
    await f.controller.selectModel('gemma3:4b');
    f.controller.setDraftText('New chat draft');
    await f.controller.pickImage();
    final image = f.controller.pendingImageReference;
    await f.controller.openConversation('existing');
    f.controller.setDraftText('Existing draft');
    await f.controller.shutdown();
    f.controller.dispose();
    f.createController();
    await f.controller.initialize();
    expect(f.controller.draftText, 'New chat draft');
    expect(f.controller.pendingImageReference, image);
    await f.controller.openConversation('existing');
    expect(f.controller.draftText, 'Existing draft');
    expect(await f.controller.send('Existing draft'), isTrue);
    await f.controller.flushDrafts();
    final saved = await f.store.loadDrafts();
    expect(saved['existing'], isNull);
    expect(saved['new:home']?['text'], 'New chat draft');
    expect(saved['new:home']?['images'], [image]);
  });

  test(
    'long chats retain local history and send only newest whole turns',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('long');
      for (var i = 0; i < 70; i++) {
        for (final role in [MessageRole.user, MessageRole.assistant]) {
          await f.store.appendMessage(
            id: 'long-$i-${role.name}',
            conversationId: 'long',
            role: role,
            status: MessageStatus.complete,
            content: '${role.name} turn $i',
          );
        }
      }
      await f.controller.initialize();
      await f.controller.openConversation('long');
      expect(await f.controller.send('Newest question'), isTrue);
      final request = f.requests.last['messages'] as List;
      expect(request.length, lessThanOrEqualTo(128));
      expect(request.first['role'], 'system');
      expect(request[1]['role'], 'user');
      expect(request.last['content'], 'Newest question');
      expect(request.any((m) => m['content'] == 'user turn 0'), isFalse);
      expect(f.controller.messages, hasLength(144));
      expect(f.controller.contextNotice, contains('older messages'));
      expect(f.controller.messages.last.status, MessageStatus.complete);
    },
  );
}
