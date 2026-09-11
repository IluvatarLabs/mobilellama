import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/chat/activity_disclosure.dart';
import 'package:mobollama/data/document_reader.dart';
import 'package:mobollama/domain/generation_options.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/domain/tool_call.dart';

import '../support/chat_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('schema-3 migration preserves stored content and adds reversible organization', () async {
    final f = ChatFixture();
    await f.open(version: 3);
    addTearDown(f.close);
    // Insert the historical schema directly: the current writer requires
    // columns that intentionally do not exist until this migration runs.
    for (final row in [
      ('home-chat', 'home', 'Quantization formats', 'Previously saved answer'),
      ('lab-chat', 'lab', 'Research', 'Quantization matters.'),
    ]) {
      await f.database.insert('conversations', {
        'id': row.$1,
        'server_profile_id': row.$2,
        'title': row.$3,
        'title_from_first_user': 1,
        'selected_model': 'qwen3:4b',
        'system_prompt': 'Be clear.',
        'generation_options_json': '{}',
        'created_at': 1000,
        'updated_at': 1000,
      });
      for (final message in [(0, 'user', row.$3), (1, 'assistant', row.$4)]) {
        await f.database.insert('messages', {
          'id': '${row.$1}-${message.$2}',
          'conversation_id': row.$1,
          'position': message.$1,
          'role': message.$2,
          'status': 'complete',
          'content': message.$3,
          'created_at': 1000,
          'updated_at': 1000,
        });
      }
    }
    final before = await f.database.rawQuery(
      'SELECT * FROM messages ORDER BY id',
    );
    final original = (await f.store.openConversation(
      serverProfileId: 'home',
      id: 'home-chat',
    ))!.conversation;
    await f.store.migrate(fromVersion: 3, legacyServerProfileId: 'home');
    expect(
      (await f.database.rawQuery('SELECT * FROM messages ORDER BY id'))
          .map((row) => {...row}..remove('documents_json'))
          .toList(),
      before,
    );
    var all = await f.store.listAllConversations();
    expect(all, hasLength(2));
    expect(
      all.every((c) => !c.isPinned && !c.isArchived && !c.isRenamed),
      isTrue,
    );
    await f.store.rename('home-chat', 'My explicit title');
    await f.store.setPinned('home-chat', true);
    await f.store.setArchived('home-chat', true);
    final renamed = (await f.store.openConversation(
      serverProfileId: 'home',
      id: 'home-chat',
    ))!.conversation;
    expect(renamed.title, 'My explicit title');
    expect(renamed.updatedAt, original.updatedAt);
    expect(renamed.selectedModel, original.selectedModel);
    expect(renamed.systemPrompt, original.systemPrompt);
    expect(renamed.isPinned && renamed.isArchived && renamed.isRenamed, isTrue);
    await f.store.appendMessage(
      id: 'later',
      conversationId: 'home-chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Another question',
    );
    expect(
      (await f.store.openConversation(
        serverProfileId: 'home',
        id: 'home-chat',
      ))!.conversation.title,
      'My explicit title',
    );
    final hits = await f.store.search('quantization');
    expect(hits.map((r) => r.conversation.id).toSet(), {
      'home-chat',
      'lab-chat',
    });
    expect(hits.where((r) => r.conversation.isArchived), hasLength(1));
    expect(await f.store.search('%'), isEmpty);
    await f.controller.initialize();
    expect(await f.controller.deleteServerProfile('home'), isFalse);
    expect(await f.controller.deleteAllConversations(), isTrue);
    expect(await f.store.listAllConversations(includeEmpty: true), isEmpty);
    expect(await f.database.rawQuery('SELECT * FROM messages'), isEmpty);
    expect(
      f.settings.listProfiles().map((p) => p.id),
      containsAll(['home', 'lab']),
    );
    expect(f.images.deleted, containsAll(['home-chat', 'lab-chat']));
  });

  test(
    'universal defaults persist independently and are sent only by new chats',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      final original = await f.seed('existing');
      await f.controller.initialize();
      await f.controller.openConversation('existing');
      expect(
        await f.controller.updateChatDefaults(
          systemPrompt: 'Be concise and cite sources.',
          generationOptions: const GenerationOptions(
            temperature: .4,
            maxTokens: 512,
          ),
        ),
        isTrue,
      );
      final reloaded = SettingsStore(f.preferences).chatDefaults;
      expect(reloaded.systemPrompt, 'Be concise and cite sources.');
      expect(reloaded.generationOptions.temperature, .4);
      expect(f.controller.systemPrompt, original.systemPrompt);
      expect(f.controller.generationOptions, original.generationOptions);
      await f.controller.newConversation();
      expect(f.controller.systemPrompt, reloaded.systemPrompt);
      expect(await f.controller.send('New question'), isTrue);
      expect(
        f.requests.last['messages'].first['content'],
        reloaded.systemPrompt,
      );
      expect(f.requests.last['options']['temperature'], .4);
      expect(f.requests.last['options']['num_predict'], 512);
    },
  );

  test('explicit default model survives opening another model and stays per server', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.seed('existing');
    await f.controller.initialize();
    expect(await f.controller.setDefaultModel('gemma3:4b'), isTrue);
    expect(SettingsStore(f.preferences).defaultModel('home'), 'gemma3:4b');
    await f.controller.openConversation('existing');
    expect(f.controller.selectedModel, 'qwen3:4b');
    expect(f.controller.defaultModelFor('home'), 'gemma3:4b');
    await f.controller.newConversation();
    expect(f.controller.selectedModel, 'gemma3:4b');
    expect(await f.controller.switchServerProfile('lab'), isTrue);
    expect(f.controller.selectedModel, 'qwen3:4b');
    expect(f.controller.defaultModelFor('lab'), isNull);
    expect(await f.controller.switchServerProfile('home'), isTrue);
    expect(f.controller.selectedModel, 'gemma3:4b');
  });

  test(
    'reconnecting for global defaults preserves a foreign offline chat',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('lab-chat', profile: 'lab');
      f.failedHosts.add('home.test');
      await f.controller.initialize();
      await f.controller.openConversation('lab-chat');
      f.controller.setDraftText('Keep this draft');
      f.failedHosts.clear();
      expect(
        await f.controller.switchServerProfile(
          'home',
          preserveConversation: true,
        ),
        isTrue,
      );
      expect(await f.controller.setDefaultModel('gemma3:4b'), isTrue);
      expect(f.controller.conversation!.id, 'lab-chat');
      expect(f.controller.draftText, 'Keep this draft');
      expect(f.controller.conversationConnected, isFalse);
      expect(f.controller.canSend, isFalse);
      await f.controller.newConversation();
      expect(f.controller.selectedModel, 'gemma3:4b');
    },
  );

  test(
    'blank startup is lazy and first send applies unsent conversation settings',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('existing');
      await f.controller.initialize();
      expect(f.controller.conversation, isNull);
      expect(f.controller.history, hasLength(1));
      await f.controller.newConversation();
      await f.controller.newConversation();
      expect(
        await f.store.listAllConversations(includeEmpty: true),
        hasLength(1),
      );
      expect(
        await f.controller.updateConversationSettings(
          systemPrompt: 'Use short sentences.',
          generationOptions: const GenerationOptions(temperature: .3),
        ),
        isTrue,
      );
      expect(await f.controller.send('Hello'), isTrue);
      expect(f.controller.conversation!.systemPrompt, 'Use short sentences.');
      expect(f.controller.conversation!.generationOptions.temperature, .3);
      expect(f.controller.messages.last.status, MessageStatus.complete);
      expect(
        f.requests.single['messages'].first['content'],
        'Use short sentences.',
      );
      expect(await f.store.listAllConversations(), hasLength(2));
      final id = f.controller.conversation!.id;
      expect(await f.controller.deleteConversation(id), isTrue);
      expect(f.controller.conversation, isNull);
      expect(f.controller.history, hasLength(1));
    },
  );

  test(
    'drafts and pending images follow their scopes without empty history rows',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('existing');
      await f.controller.initialize();
      await f.controller.selectModel('gemma3:4b');
      f.controller.setDraftText('Unsent new chat');
      await f.controller.pickImage();
      final image = f.controller.pendingImageReference;
      expect(image, isNotNull);
      expect(
        await f.store.listAllConversations(includeEmpty: true),
        hasLength(1),
      );
      await f.controller.openConversation('existing');
      expect(f.controller.draftText, '');
      expect(f.controller.pendingImageReference, isNull);
      f.controller.setDraftText('Unsent follow-up');
      await f.controller.newConversation();
      expect(f.controller.draftText, 'Unsent new chat');
      expect(f.controller.pendingImageReference, image);
      await f.controller.openConversation('existing');
      expect(f.controller.draftText, 'Unsent follow-up');
    },
  );

  test('offline cross-profile history reads never switch or send through the wrong server', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.seed('lab-chat', profile: 'lab');
    await f.controller.initialize();
    f.controller.setDraftText('Home draft');
    f.failedHosts.add('lab.test');
    await f.controller.openConversation('lab-chat');
    expect(f.controller.messages, hasLength(2));
    expect(f.controller.activeProfileId, 'home');
    expect(f.controller.conversationConnected, isFalse);
    expect(await f.controller.send('Should not send'), isFalse);
    expect(f.requests, isEmpty);
    expect(await f.controller.connectConversation(), isFalse);
    expect(f.controller.activeProfileId, 'home');
    expect(f.controller.isConnected, isTrue);
    expect(f.controller.conversation!.id, 'lab-chat');
    f.failedHosts.clear();
    expect(await f.controller.connectConversation(), isTrue);
    expect(f.controller.activeProfileId, 'lab');
    expect(f.controller.conversation!.id, 'lab-chat');
    expect(await f.controller.send('Continue here'), isTrue);
    expect(f.requests.single['host'], 'lab.test');
  });

  test(
    'opening chats reconnects their own servers and preserves scoped drafts',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('home-chat', model: 'gemma3:4b');
      await f.seed('lab-chat', profile: 'lab');
      await f.controller.initialize();
      await f.controller.openConversation('home-chat');
      f.controller.setDraftText('Keep the Home follow-up');
      await f.controller.openConversation('lab-chat');
      expect(f.controller.canSend, isTrue);
      expect(f.controller.selectedModel, 'qwen3:4b');
      expect(await f.controller.send('Lab follow-up'), isTrue);
      expect(f.requests.last['host'], 'lab.test');
      await f.controller.openConversation('home-chat');
      expect(f.controller.canSend, isTrue);
      expect(f.controller.selectedModel, 'gemma3:4b');
      expect(f.controller.draftText, 'Keep the Home follow-up');
      expect(await f.controller.send(f.controller.draftText), isTrue);
      expect(f.requests.last['host'], 'home.test');
      expect(f.requests.last['model'], 'gemma3:4b');
    },
  );

  test(
    'server settings stay scoped without replacing the current chat',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('home-chat');
      await f.controller.initialize();
      await f.controller.openConversation('home-chat');
      f.controller.setDraftText('Keep this draft');
      final options = await f.controller.loadModelsForProfile('lab');
      expect(options.map((model) => model.name), contains('gemma3:4b'));
      expect(await f.controller.setDefaultModelFor('lab', 'gemma3:4b'), isTrue);
      final lab = f.controller.profiles.firstWhere(
        (profile) => profile.id == 'lab',
      );
      expect(
        await f.controller.upsertServerProfile(lab, preserveConversation: true),
        isTrue,
      );
      expect(f.controller.activeProfileId, 'home');
      expect(f.controller.conversation!.id, 'home-chat');
      expect(f.controller.selectedModel, 'qwen3:4b');
      expect(f.controller.draftText, 'Keep this draft');
      expect(f.controller.defaultModelFor('home'), isNull);
      expect(await f.controller.newConversationOnServer('lab'), isTrue);
      expect(f.controller.conversation, isNull);
      expect(f.controller.selectedModel, 'gemma3:4b');
      await f.controller.openConversation('home-chat');
      expect(f.controller.draftText, 'Keep this draft');
      expect(await f.controller.newConversationOnServer('home'), isTrue);
      expect(f.controller.conversation, isNull);
    },
  );

  test(
    'selected server capabilities and key removal do not affect another server',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('home-chat');
      await f.controller.initialize();
      await f.controller.openConversation('home-chat');
      for (final id in ['first', 'second']) {
        expect(
          await f.controller.upsertServerProfile(
            ServerProfile(
              id: id,
              name: id,
              protocol: ServerProtocol.openAiCompatible,
              baseUrl: 'https://$id.test/v1',
            ),
            serverApiKey: '$id-test-key',
            preserveConversation: true,
          ),
          isTrue,
        );
      }
      await f.controller.setCompatibleCapability(
        'vision',
        true,
        profileId: 'second',
      );
      expect(
        f.controller.compatibleCapabilitiesForProfile('second'),
        contains('vision'),
      );
      expect(f.controller.compatibleCapabilitiesForProfile('first'), isEmpty);
      await f.controller.removeServerApiKey(profileId: 'second');
      expect(f.controller.hasServerApiKeyForProfile('second'), isFalse);
      expect(f.controller.hasServerApiKeyForProfile('first'), isTrue);
      expect(f.controller.conversation!.id, 'home-chat');
      expect(f.controller.canSend, isTrue);
      expect(await f.controller.send('Still on Home'), isTrue);
      expect(f.requests.last['host'], 'home.test');
    },
  );

  test(
    'deleting an offline chat restores the active profile draft and model',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('lab-chat', profile: 'lab');
      await f.controller.initialize();
      f.controller.setDraftText('Home draft');
      f.failedHosts.add('lab.test');
      await f.controller.openConversation('lab-chat');
      expect(f.controller.selectedModel, isNull);
      expect(await f.controller.deleteConversation('lab-chat'), isTrue);
      expect(f.controller.conversation, isNull);
      expect(f.controller.activeProfileId, 'home');
      expect(f.controller.draftText, 'Home draft');
      expect(f.controller.selectedModel, 'qwen3:4b');
      expect(f.controller.canSend, isTrue);
    },
  );

  test(
    'missing stored model preserves history and requires explicit replacement',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.seed('old', model: 'removed-model');
      await f.controller.initialize();
      await f.controller.openConversation('old');
      expect(f.controller.messages, hasLength(2));
      expect(f.controller.selectedModel, isNull);
      expect(f.controller.conversation!.selectedModel, 'removed-model');
      expect(await f.controller.send('Continue'), isFalse);
      expect(await f.controller.selectModel('qwen3:4b'), isTrue);
      expect(f.controller.conversation!.selectedModel, 'qwen3:4b');
    },
  );

  test('streaming allows navigation and Stop retains a retryable partial response', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.controller.initialize();
    f.holdResponse = true;
    final sent = f.controller.send('A long answer');
    for (var i = 0; i < 200 && !f.controller.isStreaming; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(f.controller.isStreaming, isTrue);
    final id = f.controller.conversation!.id;
    expect(await f.controller.selectModel('gemma3:4b'), isFalse);
    expect(await f.controller.switchServerProfile('lab'), isTrue);
    await f.controller.newConversation();
    expect(f.controller.conversation, isNull);
    expect(f.controller.isConversationRunning(id), isTrue);
    await f.controller.openConversation(id);
    expect(f.controller.conversation!.id, id);
    await f.controller.stop();
    expect(f.controller.canChangeContext, isTrue);
    expect(await sent, isTrue);
    expect(f.controller.messages.last.status, MessageStatus.interrupted);
    expect(f.controller.messages.last.content, isNotEmpty);
    final failedId = f.controller.messages.last.id;
    f.holdResponse = false;
    await f.controller.retryAssistant(failedId);
    expect(f.controller.messages, hasLength(2));
    expect(f.controller.messages.last.status, MessageStatus.complete);
    final count = f.requests.length;
    await f.controller.retryAssistant(f.controller.messages.last.id);
    expect(f.requests, hasLength(count));
  });

  test('Web Agent preference survives an incompatible model and only runs when effective', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.controller.initialize();
    await f.controller.saveWebApiKey('test-key');
    await f.controller.acknowledgeWebDisclosure();
    expect(await f.controller.setWebAgentEnabled(true), isTrue);
    expect(f.controller.webAgentEnabled, isTrue);
    expect(f.controller.webAgentEffective, isTrue);

    expect(await f.controller.selectModel('gemma3:4b'), isTrue);
    expect(f.controller.supportsTools, isFalse);
    expect(f.controller.webAgentEnabled, isTrue);
    expect(f.controller.webAgentEffective, isFalse);
    expect(SettingsStore(f.preferences).load().webAgentEnabled, isTrue);
    expect(await f.controller.send('Use the local model'), isTrue);
    expect(f.requests.single['model'], 'gemma3:4b');

    expect(await f.controller.selectModel('qwen3:4b'), isTrue);
    expect(f.controller.webAgentEnabled, isTrue);
    expect(f.controller.webAgentEffective, isTrue);
  });

  test(
    'image-only turns send and remain editable without invented captions',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      expect(await f.controller.send('   '), isFalse);
      expect(await f.controller.selectModel('gemma3:4b'), isTrue);
      await f.controller.pickImage();
      final reference = f.controller.pendingImageReference;
      expect(reference, isNotNull);

      expect(await f.controller.send(''), isTrue);
      final user = f.controller.messages.first;
      expect(user.content, isEmpty);
      expect(user.imageReferences, <String>[reference!]);
      final requestUser = (f.requests.last['messages'] as List).last as Map;
      expect(requestUser['content'], '');
      expect(requestUser['images'], hasLength(1));

      expect(await f.controller.editAndResend(user.id, ''), isTrue);
      expect(f.controller.messages.first.content, isEmpty);
      expect(f.controller.messages.first.imageReferences, <String>[reference]);
    },
  );

  test('document-only turns send, remain editable, and export their readable content', () async {
    final directory = await Directory.systemTemp.createTemp(
      'mobilellama-document-only-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = await File('${directory.path}/brief.txt')
        .writeAsString('The launch date is Tuesday.');
    final f = ChatFixture()
      ..documentReader = DocumentReader(picker: () async => XFile(file.path));
    await f.open();
    addTearDown(f.close);
    await f.controller.initialize();
    await f.controller.pickDocument();
    final document = f.controller.pendingDocuments.single;

    expect(await f.controller.send(''), isTrue);
    final user = f.controller.messages.first;
    expect(user.content, isEmpty);
    expect(user.documents.single.reference, document.reference);
    final requestUser = (f.requests.last['messages'] as List).last as Map;
    expect(requestUser['content'], contains('brief.txt'));
    expect(requestUser['content'], contains('The launch date is Tuesday.'));

    expect(await f.controller.editAndResend(user.id, ''), isTrue);
    expect(
      f.controller.messages.first.documents.single.reference,
      document.reference,
    );
    final markdown = await f.controller.conversationMarkdown(
      f.controller.conversation!.id,
    );
    expect(markdown, contains('_No text content._'));
    expect(markdown, contains('Attached document: brief.txt'));
    expect(markdown, contains('The launch date is Tuesday.'));
  });

  test(
    'retry insert failure retains the original partial response and tool state',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.store.createConversation(
        id: 'retry-chat',
        serverProfileId: 'home',
        selectedModel: 'qwen3:4b',
        systemPrompt: '',
      );
      await f.store.appendMessage(
        id: 'retry-user',
        conversationId: 'retry-chat',
        role: MessageRole.user,
        status: MessageStatus.complete,
        content: 'Use a tool',
      );
      final partial = await f.store.appendMessage(
        id: 'retry-assistant',
        conversationId: 'retry-chat',
        role: MessageRole.assistant,
        status: MessageStatus.interrupted,
        content: 'Saved partial',
        reasoning: 'Saved thinking',
        toolCalls: const <ToolCall>[
          ToolCall(id: 'call-1', name: 'browser', arguments: {'q': 'docs'}),
        ],
        toolResults: const <ToolResult>[
          ToolResult(
            id: 'result-1',
            toolCallId: 'call-1',
            content: 'Saved result',
          ),
        ],
      );
      await f.store.updateMessage(
        partial.copyWith(
          providerTranscriptJson:
              '[{"role":"assistant","content":"Saved partial"}]',
        ),
      );
      await f.controller.initialize();
      await f.controller.openConversation('retry-chat');
      await f.database.execute('''
        CREATE TRIGGER reject_retry_insert
        BEFORE INSERT ON messages
        WHEN NEW.status = 'streaming'
        BEGIN
          SELECT RAISE(ABORT, 'injected retry insert failure');
        END
      ''');

      await f.controller.retryAssistant('retry-assistant');

      final inMemory = f.controller.messages.last;
      final persisted = (await f.store.openConversation(
        serverProfileId: 'home',
        id: 'retry-chat',
      ))!.messages.last;
      for (final message in <Message>[inMemory, persisted]) {
        expect(message.id, 'retry-assistant');
        expect(message.status, MessageStatus.interrupted);
        expect(message.content, 'Saved partial');
        expect(message.reasoning, 'Saved thinking');
        expect(message.providerTranscriptJson, isNotNull);
        expect(message.toolCalls.single.id, 'call-1');
        expect(message.toolResults.single.content, 'Saved result');
      }
      expect(f.controller.transcriptMessages.last.canRetry, isTrue);
      expect(
        f.controller.errorMessage,
        contains('injected retry insert failure'),
      );
      expect(f.requests, isEmpty);
    },
  );

  test(
    'server deletion preserves its unsent draft until the user discards it',
    () async {
      final f = ChatFixture();
      await f.open();
      addTearDown(f.close);
      await f.controller.initialize();
      expect(await f.controller.switchServerProfile('lab'), isTrue);
      f.controller.setDraftText('Unsent Lab request');
      expect(
        await f.controller.updateConversationSettings(
          systemPrompt: 'Use the Lab format.',
          generationOptions: const GenerationOptions(temperature: .2),
        ),
        isTrue,
      );
      await f.controller.flushDrafts();
      expect(await f.controller.switchServerProfile('home'), isTrue);

      expect(await f.controller.deleteServerProfile('lab'), isFalse);
      expect(
        f.controller.errorMessage,
        contains('Open this server and send or discard the draft'),
      );
      final saved = await f.store.loadDrafts();
      expect(saved['new:lab']?['text'], 'Unsent Lab request');
      expect(saved['new:lab']?['systemPrompt'], 'Use the Lab format.');

      expect(await f.controller.switchServerProfile('lab'), isTrue);
      expect(f.controller.draftText, 'Unsent Lab request');
      await f.controller.discardCurrentDraft();
      expect(await f.controller.deleteServerProfile('lab'), isTrue);
      expect(
        f.controller.profiles.map((profile) => profile.id),
        isNot(contains('lab')),
      );
      expect((await f.store.loadDrafts()).containsKey('new:lab'), isFalse);
    },
  );

  test('non-string provider tool labels render as failed activity', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    await f.store.createConversation(
      id: 'tool-label-chat',
      serverProfileId: 'home',
      selectedModel: 'qwen3:4b',
      systemPrompt: '',
    );
    await f.store.appendMessage(
      id: 'tool-label-user',
      conversationId: 'tool-label-chat',
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: 'Use the provider tool',
    );
    await f.store.appendMessage(
      id: 'tool-label-assistant',
      conversationId: 'tool-label-chat',
      role: MessageRole.assistant,
      status: MessageStatus.failed,
      content: '',
      toolCalls: const <ToolCall>[
        ToolCall(
          id: 'provider-call',
          name: 'browser_search',
          arguments: <String, Object?>{'label': 7},
        ),
      ],
      toolResults: const <ToolResult>[
        ToolResult(
          id: 'provider-result',
          toolCallId: 'provider-call',
          content: 'Unsupported tool',
          isError: true,
        ),
      ],
    );
    await f.controller.initialize();
    await f.controller.openConversation('tool-label-chat');

    final activity = f.controller.transcriptMessages.last.toolCalls.single;
    expect(activity.label, 'Browser search');
    expect(activity.detail, 'Unsupported tool');
    expect(activity.state, ToolActivityState.failed);
  });
}
