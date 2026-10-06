// Opt-in acceptance against a disposable, authenticated Open WebUI server.
// MOBILELLAMA_LIVE_WEBUI_CONFIG=/private/config.json flutter test \
//   test_driver/live_webui_test.dart --no-pub --reporter expanded
// Config: endpoint, email, password, model, skillId, toolId. The disposable
// skill must provide laboratory code cedar84; the disposable tool must expose
// observatory_code returning maple29. Never commit the config or tokens.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/ollama/connection_options.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/conversation.dart';
import 'package:mobollama/open_webui/export.dart';
import 'package:mobollama/open_webui/files.dart';
import 'package:mobollama/open_webui/folders.dart';
import 'package:mobollama/open_webui/resources.dart';
import 'package:mobollama/open_webui/run.dart';
import 'package:mobollama/open_webui/socket.dart';
import 'package:mobollama/open_webui/temporary.dart';
import 'package:mobollama/open_webui/workspace.dart';

import '../test/support/chat_fixture.dart';

// Fault injection forwards real requests. It never synthesizes server output.
class _Transport extends http.BaseClient {
  final http.Client inner = http.Client();
  String? dropNext;
  int completions = 0;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final completion = request.url.path.endsWith('/api/chat/completions');
    final drop = completion ? dropNext : null;
    if (completion) dropNext = null;
    if (drop == 'before') {
      throw const SocketException('Injected pre-dispatch loss');
    }
    if (completion) completions++;
    final response = await inner.send(request);
    if (drop == 'after') {
      await response.stream.drain<void>();
      throw const SocketException('Injected lost acknowledgment');
    }
    return response;
  }

  @override
  void close() => inner.close();
}

Future<void> until(bool Function() ready, String failure) async {
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (!ready() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  expect(ready(), isTrue, reason: failure);
}

void main() {
  final path = Platform.environment['MOBILELLAMA_LIVE_WEBUI_CONFIG'];
  if (path == null) throw StateError('Set MOBILELLAMA_LIVE_WEBUI_CONFIG.');
  final config = jsonDecode(File(path).readAsStringSync()) as Map;

  test('live shared chat: auth, branches, folders, files, export and temporary Save', () async {
    final f = ChatFixture();
    await f.open();
    await f.controller.initialize();
    addTearDown(f.close);
    final directory = await Directory.systemTemp.createTemp(
      'mobilellama-live-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final guest = OpenWebUiClient(
      baseUrl: config['endpoint'] as String,
      options: ConnectionOptions(),
    );
    final login = await guest.signIn(
      config['email'] as String,
      config['password'] as String,
    );
    final transport = _Transport();
    final client = OpenWebUiClient(
      baseUrl: config['endpoint'] as String,
      options: ConnectionOptions(apiKey: login['token'] as String),
      client: transport,
    );
    guest.close();
    addTearDown(client.close);
    final session = WebUiSession('live-webui', await client.identity(), client);
    await f.store.webUi.unlock(session.capture());
    final accounts = WebUiAccounts(
      f.settings,
      ProfileCredentials(f.secrets),
      f.store.webUi,
    );
    final workspace = WebUiWorkspace(
      accounts,
      session,
      files: WebUiFiles(directory),
    );
    addTearDown(workspace.dispose);
    await workspace.initialize();
    expect(workspace.online, isTrue, reason: workspace.error);
    expect(workspace.models.any((m) => m['id'] == config['model']), isTrue);
    await workspace.selectModel(config['model'] as String);
    await until(
      () => workspace.socket.sessionId != null,
      'Authenticated socket did not connect',
    );

    Future<void> settle() async {
      await until(
        () => workspace.run?.terminal == true,
        'The server response did not settle',
      );
      expect(
        workspace.run!.state,
        WebUiRunState.completed,
        reason: workspace.run!.problem,
      );
      await until(
        () => workspace.conversation?.tip == workspace.run!.assistantId,
        'Saved server history did not contain the completed response',
      );
    }

    expect(
      await workspace.send(
        'Remember the code apricot73. Reply only acknowledged.',
      ),
      isTrue,
    );
    await settle();
    final chatId = workspace.conversation!.id;
    expect(
      await workspace.send(
        'What code did I ask you to remember? Reply only with the code.',
      ),
      isTrue,
    );
    await settle();
    expect(
      webUiMessageText(workspace.conversation!.branch().last).toLowerCase(),
      contains('apricot73'),
    );
    final original = workspace.conversation!.tip!;
    expect(await workspace.revise(original), isTrue);
    await settle();
    expect(workspace.versionsOf(original), hasLength(2));
    workspace.viewVersion(original);
    expect(workspace.previewingVersion, isTrue);
    await workspace.continueViewedVersion();
    expect(
      await workspace.send('Repeat the remembered code with no extra words.'),
      isTrue,
      reason: workspace.error,
    );
    await settle();
    expect(workspace.conversation!.nodes[original], isNotNull);
    expect(
      webUiMessageText(workspace.conversation!.branch().last).toLowerCase(),
      contains('apricot73'),
    );

    workspace.setDraft('Keep this unsent thought');
    await workspace.flushDraft();
    await workspace.open(null);
    await workspace.open(chatId);
    expect(workspace.draft, 'Keep this unsent thought');
    final folders = WebUiFolders(session);
    final folderName = 'Acceptance ${DateTime.now().millisecondsSinceEpoch}';
    await folders.save(name: folderName, instructions: 'Answer concisely.');
    final folder = (await folders.list()).singleWhere(
      (item) => item['name'] == folderName,
    );
    await folders.moveChat(chatId, folder['id'] as String);
    expect(
      (await folders.chats(
        folder,
        1,
      )).chats.any((chat) => chat['id'] == chatId),
      isTrue,
    );
    await folders.deleteKeepingChats(folder['id'] as String);
    expect((await client.chat(chatId, session.capture()))['id'], chatId);

    for (final kind in WebUiResourceKind.values) {
      await workspace.serverResources.list(kind);
    }
    await workspace.addFile(
      'acceptance.txt',
      utf8.encode('The telescope code is cobalt91.'),
    );
    await until(
      () => workspace.uploads.every(
        (item) => item['state'] == 'ready' || item['state'] == 'failed',
      ),
      'The uploaded file did not finish processing',
    );
    expect(
      workspace.attachmentsReady,
      isTrue,
      reason: workspace.uploads.toString(),
    );
    workspace.setDraft('');
    expect(
      await workspace.send(
        'According to the attached file, what is the telescope code?',
      ),
      isTrue,
      reason: workspace.error,
    );
    await settle();
    expect(
      webUiMessageText(workspace.conversation!.branch().last).toLowerCase(),
      contains('cobalt91'),
    );
    final fileId = (workspace.resources['files'] as List).first['id'] as String;
    expect(
      await workspace.serverResources.sourceText(fileId),
      contains('cobalt91'),
    );
    final knowledge = Map<String, dynamic>.from(
      await client.request(
        'POST',
        'api/v1/knowledge/create',
        lease: session.capture(),
        body: {
          'name': 'Acceptance knowledge',
          'description': 'Disposable test document',
        },
      ) as Map,
    );
    await client.request(
      'POST',
      'api/v1/knowledge/${knowledge['id']}/file/add',
      lease: session.capture(),
      body: {'file_id': fileId},
    );
    await workspace.open(null);
    await workspace.setResource(WebUiResourceKind.knowledge, knowledge, true);
    expect(
      await workspace.send(
        'According to the selected knowledge, what is the telescope code?',
      ),
      isTrue,
    );
    await settle();
    expect(
      webUiMessageText(workspace.conversation!.branch().last).toLowerCase(),
      contains('cobalt91'),
    );
    expect(
      WebUiResources.sources(workspace.conversation!.branch().last)
          .any((source) => source.fileId == fileId),
      isTrue,
    );

    for (final entry in [
      (
        WebUiResourceKind.skills,
        'skillId',
        'What is the laboratory code?',
        'cedar84',
      ),
      (
        WebUiResourceKind.tools,
        'toolId',
        'Use the observatory_code tool to look up the current observatory code. Reply with its result.',
        'maple29',
      ),
    ]) {
      final resource = (await workspace.serverResources.list(entry.$1)).items
          .singleWhere((item) => item['id'] == config[entry.$2]);
      await workspace.open(null);
      await workspace.setResource(entry.$1, resource, true);
      expect(await workspace.send(entry.$3), isTrue, reason: workspace.error);
      await settle();
      expect(
        webUiMessageText(workspace.conversation!.branch().last).toLowerCase(),
        contains(entry.$4),
      );
      final selectedChatId = workspace.conversation!.id;
      await workspace.open(null);
      await workspace.open(selectedChatId);
      expect(
        workspace.resources[entry.$1 == WebUiResourceKind.skills
            ? 'skill_ids'
            : 'tool_ids'],
        contains(resource['id']),
      );
    }
    final exporter = WebUiExport(session, f.store.webUi);
    final exported = await exporter.completeBranch(chatId);
    expect(exporter.markdown(exported), contains('cobalt91'));
    expect(
      await f.controller.importBackup(
        exporter.portableJson(exported),
        localDestinationId: 'home',
      ),
      1,
    );

    final before = (await client.chats(lease: session.capture()))
        .map((chat) => chat['id'])
        .toSet();
    final temporary = WebUiTemporaryChat(
      session,
      WebUiSocket(session),
      model: config['model'] as String,
    );
    addTearDown(temporary.dispose);
    await temporary.initialize();
    expect(await temporary.send('Reply only with temporary47.'), isTrue);
    await until(() => !temporary.running, 'Temporary response did not settle');
    expect(temporary.problem, isNull);
    if (!temporary.messages.last.content.toLowerCase().contains(
      'temporary47',
    )) {
      // This opt-in fixture uses only synthetic disposable conversation text.
      // ignore: avoid_print
      print('Unexpected temporary result: ${jsonEncode(temporary.nodes.last)}');
    }
    expect(
      temporary.messages.last.content.toLowerCase(),
      contains('temporary47'),
    );
    expect(
      (await client.chats(lease: session.capture()))
          .map((chat) => chat['id'])
          .toSet(),
      before,
    );
    temporary.setDraft('Keep this draft after Save');
    final savedId = await temporary.save(accounts);
    expect(await temporary.save(accounts), savedId);
    final saved = WebUiConversation(
      await client.chat(savedId, session.capture()),
    );
    expect(
      webUiMessageText(saved.branch().last).toLowerCase(),
      contains('temporary47'),
    );
    expect(
      (await f.store.webUi.draft(session.capture(), savedId))?['text'],
      'Keep this draft after Save',
    );

    for (final loss in ['before', 'after']) {
      await workspace.open(null);
      final dispatched = transport.completions;
      transport.dropNext = loss;
      expect(await workspace.send('Reply only with recovered31.'), isTrue);
      await until(
        () =>
            workspace.run?.state == WebUiRunState.uncertain ||
            workspace.run?.terminal == true,
        'Injected loss did not settle',
      );
      final run = workspace.run!;
      if (loss == 'before') {
        await run.reconcile();
        expect(run.state, WebUiRunState.uncertain);
        expect(transport.completions, dispatched);
      } else {
        for (var i = 0; i < 120 && !run.terminal; i++) {
          await run.reconcile();
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(run.state, WebUiRunState.completed, reason: run.problem);
        expect(run.partial.toLowerCase(), contains('recovered31'));
        expect(transport.completions, dispatched + 1);
        final graph = WebUiConversation(
          await client.chat(run.chatId!, session.capture()),
        );
        expect(
          graph.nodes.values.where((node) => node['role'] == 'user'),
          hasLength(1),
        );
      }
    }
    await workspace.open(null);
    final beforeStop = transport.completions;
    expect(
      await workspace.send(
        'Write a detailed 2000 word explanation of how rain forms.',
      ),
      isTrue,
    );
    await until(
      () => workspace.run?.partial.isNotEmpty == true,
      'The cancellable answer did not start',
    );
    expect(
      await workspace.send('Keep this queued until I explicitly resume.'),
      isTrue,
    );
    await workspace.run!.stop();
    await until(
      () => workspace.run!.terminal,
      'The stopped task did not settle',
    );
    expect(workspace.run!.state, WebUiRunState.stopped);
    expect(workspace.run!.partial, isNotEmpty);
    expect(workspace.queuePaused, isTrue);
    expect(workspace.queue, hasLength(1));
    expect(transport.completions, beforeStop + 1);
    // ignore: avoid_print
    print('Live acceptance chat available for desktop continuity: $chatId');
  }, timeout: const Timeout(Duration(minutes: 15)));
}
