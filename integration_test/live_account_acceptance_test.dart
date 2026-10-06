import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobollama/app.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/ollama/connection_options.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';
import 'package:mobollama/open_webui/conversation.dart';
import 'package:mobollama/open_webui/files.dart';
import 'package:mobollama/open_webui/run.dart';
import 'package:mobollama/open_webui/workspace.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('live account isolation, concurrency, inventory, and API key', (
    tester,
  ) async {
    const root = String.fromEnvironment('prefixedEndpoint');
    const model = String.fromEnvironment('model');
    const adminToken = String.fromEnvironment('adminToken');
    const aEmail = String.fromEnvironment('aEmail');
    const aPassword = String.fromEnvironment('aPassword');
    const aId = String.fromEnvironment('aId');
    const aToken = String.fromEnvironment('aToken');
    const bEmail = String.fromEnvironment('bEmail');
    const bPassword = String.fromEnvironment('bPassword');
    const bId = String.fromEnvironment('bId');
    const bToken = String.fromEnvironment('bToken');
    const runId = String.fromEnvironment('runId');
    expect(
      [
        root,
        model,
        adminToken,
        aEmail,
        aPassword,
        aId,
        aToken,
        bEmail,
        bPassword,
        bId,
        bToken,
        runId,
      ].every((value) => value.isNotEmpty),
      isTrue,
    );

    OpenWebUiClient client(String token) => OpenWebUiClient(
      baseUrl: root,
      options: ConnectionOptions(
        authentication: ServerAuthentication.bearer,
        apiKey: token,
      ),
    );

    final admin = client(adminToken);
    final cleanupA = client(aToken);
    final cleanupB = client(bToken);
    final createdChats = <String>{};
    final createdBChats = <String>{};
    String? createdFileId;
    var apiKeyCreated = false;
    Map<String, dynamic>? originalAdminConfig;
    Map<String, dynamic>? originalPermissions;
    List<dynamic>? originalModelAccess;
    var modelRecordCreated = false;
    ChatControllerBootstrap? bootstrap;
    WebUiAccounts? openedAccounts;
    WebUiWorkspace? workspaceA;
    WebUiWorkspace? workspaceA2;
    WebUiSession? keySession;
    final outcomes = <String, Object?>{};

    Future<Map<String, dynamic>> objectRequest(
      OpenWebUiClient target,
      String method,
      String path, {
      Object? body,
    }) async {
      final value = await target.request(method, path, body: body);
      if (value is! Map) throw StateError('Expected an object from $path.');
      return Map<String, dynamic>.from(value);
    }

    Future<void> setRole(String role) async {
      await admin.request(
        'POST',
        'api/v1/users/${Uri.encodeComponent(aId)}/update',
        body: {'role': role},
      );
    }

    Future<int?> webUiFailure(Future<void> Function() action) async {
      try {
        await action();
      } on WebUiException catch (error) {
        return error.status;
      }
      return null;
    }

    Future<void> waitFor(
      bool Function() predicate, {
      int attempts = 1200,
      String? reason,
    }) async {
      for (var attempt = 0; attempt < attempts && !predicate(); attempt++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(predicate(), isTrue, reason: reason);
    }

    Future<void> waitForRun(WebUiWorkspace workspace) async {
      await waitFor(
        () => workspace.run?.terminal == true,
        reason: workspace.run?.problem ?? workspace.error,
      );
      expect(
        workspace.run?.state,
        WebUiRunState.completed,
        reason: workspace.run?.problem ?? workspace.error,
      );
    }

    final profileA = ServerProfile(
      id: 'live-account-a-$runId',
      name: 'Live account A',
      protocol: ServerProtocol.openWebUi,
      baseUrl: root,
      acknowledgedInsecureOrigin: Uri.parse(root).origin,
    );
    final profileB = ServerProfile(
      id: 'live-account-b-$runId',
      name: 'Live account B',
      protocol: ServerProtocol.openWebUi,
      baseUrl: root,
      acknowledgedInsecureOrigin: Uri.parse(root).origin,
    );
    final profileKey = ServerProfile(
      id: 'live-account-key-$runId',
      name: 'Live account API key',
      protocol: ServerProtocol.openWebUi,
      baseUrl: root,
      acknowledgedInsecureOrigin: Uri.parse(root).origin,
    );

    try {
      // Recover a prior interrupted acceptance run before changing global test
      // server configuration, then retain exact originals for restoration.
      await setRole('user');
      originalAdminConfig = await objectRequest(
        admin,
        'GET',
        'api/v1/auths/admin/config',
      );
      originalPermissions = await objectRequest(
        admin,
        'GET',
        'api/v1/users/default/permissions',
      );
      final enabledConfig = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(originalAdminConfig)) as Map,
      )..['ENABLE_API_KEYS'] = true;
      final enabledPermissions = Map<String, dynamic>.from(
        jsonDecode(jsonEncode(originalPermissions)) as Map,
      );
      (enabledPermissions['features'] as Map)['api_keys'] = true;
      await admin.request(
        'POST',
        'api/v1/auths/admin/config',
        body: enabledConfig,
      );
      await admin.request(
        'POST',
        'api/v1/users/default/permissions',
        body: enabledPermissions,
      );
      final modelRecords = await admin.request('GET', 'api/v1/models/all');
      if (modelRecords is! List) {
        throw StateError('Expected the server model catalog.');
      }
      final existingModel = modelRecords.whereType<Map>().where(
        (item) => item['id'] == model,
      );
      if (existingModel.isEmpty) {
        modelRecordCreated = true;
      } else {
        originalModelAccess = List<dynamic>.from(
          existingModel.single['access_grants'] as List? ?? const [],
        );
      }
      await admin.request(
        'POST',
        'api/v1/models/model/access/update',
        body: {
          'id': model,
          'name': model,
          'access_grants': [
            {
              'principal_type': 'user',
              'principal_id': aId,
              'permission': 'read',
            },
            {
              'principal_type': 'user',
              'principal_id': bId,
              'permission': 'read',
            },
          ],
        },
      );

      bootstrap = await createChatController();
      final accounts = bootstrap.controller.webUiAccounts;
      openedAccounts = accounts;
      final sessionA = await accounts.open(
        profileA,
        email: aEmail,
        password: aPassword,
      );
      expect(sessionA.identity.userId, aId);
      expect(sessionA.identity.server, root);
      outcomes['prefixed_password_sign_in'] = true;

      workspaceA = WebUiWorkspace(accounts, sessionA);
      await workspaceA.initialize();
      workspaceA.model = model;
      expect(workspaceA.models.any((item) => item['id'] == model), isTrue);
      expect(await workspaceA.send('Reply only with account-$runId.'), isTrue);
      await waitForRun(workspaceA);
      final primaryChatId = workspaceA.run!.chatId!;
      createdChats.add(primaryChatId);
      await workspaceA.open(primaryChatId);
      expect(workspaceA.conversation?.id, primaryChatId);

      await workspaceA.addFile(
        'isolation-$runId.txt',
        utf8.encode('private account A resource $runId'),
      );
      await waitFor(
        () => workspaceA!.uploads.singleOrNull?['state'] == 'ready',
        reason: workspaceA.error,
      );
      final upload = workspaceA.uploads.single;
      final stagedPath = upload['path'] as String;
      createdFileId = upload['remoteId'] as String;
      expect(await File(stagedPath).exists(), isTrue);
      workspaceA.setDraft('retained phone draft $runId');
      await workspaceA.flushDraft();
      final queueId = 'queue-$runId';
      await accounts.store.saveQueued(
        sessionA.capture(),
        queueId,
        primaryChatId,
        {
          'id': queueId,
          'text': 'retained queue item $runId',
          'model': model,
          'resources': const <String, dynamic>{},
          'createdAt': DateTime.now().toUtc().toIso8601String(),
        },
      );

      final cleanMessageId = 'clean-message-$runId';
      final clean = await sessionA.client.createChat({
        'title': 'Inventory acceptance $runId',
        'models': [model],
        'history': {
          'messages': {
            cleanMessageId: {
              'id': cleanMessageId,
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'inventory acceptance $runId',
              'models': [model],
              'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            },
          },
          'currentId': cleanMessageId,
        },
        'messages': <Map<String, dynamic>>[],
        'params': <String, dynamic>{},
      }, sessionA.capture());
      final cleanChatId = clean['id'] as String;
      createdChats.add(cleanChatId);
      await accounts.store.refreshChat(sessionA, cleanChatId);
      expect(
        await accounts.store.chat(sessionA.capture(), cleanChatId),
        isNotNull,
      );

      final expiredLease = sessionA.capture();
      await setRole('pending');
      await workspaceA.synchronizeInventory();
      expect(sessionA.locked, isTrue);
      expect(() => expiredLease.check(), throwsA(isA<WebUiException>()));
      outcomes['real_401_locked_session'] = true;

      final sessionB = await accounts.open(
        profileB,
        email: bEmail,
        password: bPassword,
      );
      expect(sessionB.identity.userId, bId);
      final bLease = sessionB.capture();
      final bChats = await accounts.store.chats(bLease);
      expect(
        bChats.any(
          (chat) => chat['id'] == primaryChatId || chat['id'] == cleanChatId,
        ),
        isFalse,
      );
      expect(await accounts.store.draft(bLease, primaryChatId), isNull);
      expect(await accounts.store.queue(bLease, primaryChatId), isEmpty);
      final bFiles = await WebUiFiles.create();
      expect(
        () => bFiles.read(bLease, stagedPath),
        throwsA(isA<WebUiException>()),
      );
      final bFileStatus = await webUiFailure(
        () async => sessionB.client.fileBytes(
          'api/v1/files/${Uri.encodeComponent(createdFileId!)}/content',
          bLease,
        ),
      );
      expect(bFileStatus, 404);
      expect(sessionB.locked, isFalse);
      expect((await sessionB.client.identity()).userId, bId);
      final bChatStatus = await webUiFailure(
        () async => sessionB.client.chat(primaryChatId, bLease),
      );
      expect(bChatStatus, 401);
      expect(sessionB.locked, isTrue);
      outcomes['b_local_partition_isolated'] = true;
      outcomes['b_server_chat_and_file_denied'] = true;

      final sessionB2 = await accounts.open(
        profileB,
        email: bEmail,
        password: bPassword,
      );
      expect(sessionB2.identity.userId, bId);
      final bOwnMessage = 'b-own-$runId';
      final bOwn = await sessionB2.client.createChat({
        'title': 'B account acceptance $runId',
        'models': [model],
        'history': {
          'messages': {
            bOwnMessage: {
              'id': bOwnMessage,
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'B account acceptance $runId',
              'models': [model],
              'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            },
          },
          'currentId': bOwnMessage,
        },
        'messages': <Map<String, dynamic>>[],
        'params': <String, dynamic>{},
      }, sessionB2.capture());
      final bOwnChatId = bOwn['id'] as String;
      createdBChats.add(bOwnChatId);
      expect(
        (await sessionB2.client.chat(bOwnChatId, sessionB2.capture()))['id'],
        bOwnChatId,
      );
      outcomes['b_reauthenticated_and_own_chat_usable'] = true;

      await setRole('user');
      final sessionA2 = await accounts.open(
        profileA,
        email: aEmail,
        password: aPassword,
      );
      final a2Lease = sessionA2.capture();
      expect(
        (await accounts.store.chats(a2Lease))
            .any((chat) => chat['id'] == primaryChatId),
        isTrue,
      );
      expect(
        (await accounts.store.draft(a2Lease, primaryChatId))?['text'],
        'retained phone draft $runId',
      );
      expect(
        (await accounts.store.queue(
          a2Lease,
          primaryChatId,
        )).any((item) => item['id'] == queueId),
        isTrue,
      );
      expect(
        (await accounts.store.stagedReferences(a2Lease)).contains(stagedPath),
        isTrue,
      );
      expect(await File(stagedPath).exists(), isTrue);
      outcomes['a_reconnect_retained_local_state'] = true;
      outcomes['denied_inventory_retained_cache'] =
          await accounts.store.chat(a2Lease, cleanChatId) != null;
      expect(outcomes['denied_inventory_retained_cache'], isTrue);

      workspaceA2 = WebUiWorkspace(accounts, sessionA2);
      await workspaceA2.initialize();
      workspaceA2.model = model;
      await workspaceA2.open(primaryChatId);
      await accounts.store.removeQueued(a2Lease, queueId);
      await workspaceA2.removeUpload(upload['localId'] as String);
      workspaceA2.setDraft('phone continuation $runId');
      await workspaceA2.flushDraft();
      final phoneParent = workspaceA2.conversation!.tip!;
      final phoneParentFingerprint = workspaceA2.conversation!.fingerprint(
        phoneParent,
      );

      final desktopClient = client(aToken);
      final desktopIdentity = await desktopClient.identity();
      final desktopSession = WebUiSession(
        'desktop-actor-$runId',
        desktopIdentity,
        desktopClient,
      );
      final desktopRun = await WebUiRun.prepare(
        session: desktopSession,
        store: accounts.store,
        chatId: primaryChatId,
        expectedParentId: phoneParent,
        revisionTargetId: phoneParent,
        revisionFingerprint: phoneParentFingerprint,
        regenerate: true,
        text: '',
        model: model,
      );
      await desktopRun.dispatch();
      expect(
        desktopRun.state,
        WebUiRunState.completed,
        reason: desktopRun.problem,
      );
      final desktopAssistant = desktopRun.assistantId;
      desktopRun.dispose();
      desktopSession.lock();
      desktopClient.close();

      await workspaceA2.refreshConversation();
      expect(workspaceA2.draft, 'phone continuation $runId');
      expect(workspaceA2.diverged, isTrue);
      final graphBeforeRefusal = WebUiConversation(
        await sessionA2.client.chat(primaryChatId, a2Lease),
      );
      expect(await workspaceA2.send(workspaceA2.draft), isFalse);
      await tester.pump(const Duration(milliseconds: 500));
      final graphAfterRefusal = WebUiConversation(
        await sessionA2.client.chat(primaryChatId, a2Lease),
      );
      expect(
        graphAfterRefusal.nodes.keys.toSet(),
        graphBeforeRefusal.nodes.keys.toSet(),
      );
      expect(workspaceA2.draft, 'phone continuation $runId');
      outcomes['stale_send_refused_without_dispatch'] = true;

      await workspaceA2.adoptContinuation();
      expect(workspaceA2.diverged, isFalse);
      expect(await workspaceA2.send(workspaceA2.draft), isTrue);
      await waitForRun(workspaceA2);
      final phoneAssistant = workspaceA2.run!.assistantId;
      final finalGraph = WebUiConversation(
        await sessionA2.client.chat(primaryChatId, a2Lease),
      );
      expect(finalGraph.nodes.containsKey(phoneParent), isTrue);
      expect(finalGraph.nodes.containsKey(desktopAssistant), isTrue);
      expect(finalGraph.nodes.containsKey(phoneAssistant), isTrue);
      expect(
        finalGraph.versions(phoneParent),
        containsAll([phoneParent, desktopAssistant]),
      );
      expect(
        finalGraph
            .branch(tipId: phoneAssistant)
            .any((node) => node['id'] == desktopAssistant),
        isTrue,
      );
      outcomes['both_siblings_and_adopted_continuation_retained'] = true;

      await sessionA2.client.deleteChat(cleanChatId, a2Lease);
      createdChats.remove(cleanChatId);
      await workspaceA2.synchronizeInventory();
      expect(await accounts.store.chat(a2Lease, cleanChatId), isNull);
      await workspaceA2.synchronizeInventory();
      expect(await accounts.store.chat(a2Lease, cleanChatId), isNull);
      outcomes['confirmed_server_delete_removed_cache_without_resurrection'] =
          true;

      final generated = await objectRequest(
        sessionA2.client,
        'POST',
        'api/v1/auths/api_key',
      );
      final apiKey = generated['api_key'];
      expect(apiKey, isA<String>());
      expect((apiKey as String).isNotEmpty, isTrue);
      apiKeyCreated = true;
      keySession = await accounts.open(profileKey, token: apiKey);
      expect(keySession.identity.userId, aId);
      expect(keySession.identity.server, root);
      final keyChats = await keySession.client.chats(
        lease: keySession.capture(),
      );
      expect(keyChats.any((chat) => chat['id'] == primaryChatId), isTrue);
      outcomes['prefixed_api_key_product_sign_in'] = true;

      await sessionA2.client.request('DELETE', 'api/v1/auths/api_key');
      apiKeyCreated = false;
      keySession.lock();
      keySession.client.close();

      await sessionA2.client.deleteChat(primaryChatId, a2Lease);
      createdChats.remove(primaryChatId);
      await sessionA2.client.request(
        'DELETE',
        'api/v1/files/${Uri.encodeComponent(createdFileId)}',
        lease: a2Lease,
      );
      createdFileId = null;

      final signOutMessageId = 'signout-message-$runId';
      final signOutChat = await sessionA2.client.createChat({
        'title': 'Sign-out acceptance $runId',
        'models': [model],
        'history': {
          'messages': {
            signOutMessageId: {
              'id': signOutMessageId,
              'parentId': null,
              'childrenIds': <String>[],
              'role': 'user',
              'content': 'server history retained after sign-out $runId',
              'models': [model],
              'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            },
          },
          'currentId': signOutMessageId,
        },
        'messages': <Map<String, dynamic>>[],
        'params': <String, dynamic>{},
      }, a2Lease);
      final signOutChatId = signOutChat['id'] as String;
      createdChats.add(signOutChatId);
      await accounts.store.refreshChat(sessionA2, signOutChatId);
      final signOutFiles = await WebUiFiles.create();
      final signOutStage = await signOutFiles.stage(
        a2Lease,
        'signout-$runId.txt',
        utf8.encode('unsent local account A resource $runId'),
      );
      final signOutStagePath = signOutStage['path'] as String;
      await accounts.store.saveDraft(a2Lease, signOutChatId, {
        'text': 'unsent at sign-out $runId',
        'parentId': signOutMessageId,
        'resources': {
          'uploads': [signOutStage],
        },
        'model': model,
      });
      final signOutQueueId = 'signout-queue-$runId';
      await accounts.store.saveQueued(a2Lease, signOutQueueId, signOutChatId, {
        'id': signOutQueueId,
        'text': 'queued at sign-out $runId',
        'model': model,
        'resources': const <String, dynamic>{},
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      });
      expect(await accounts.store.chat(a2Lease, signOutChatId), isNotNull);
      expect(
        (await accounts.store.draft(a2Lease, signOutChatId))?['text'],
        'unsent at sign-out $runId',
      );
      expect(await accounts.store.queue(a2Lease, signOutChatId), isNotEmpty);
      expect(await File(signOutStagePath).exists(), isTrue);

      await accounts.signOut(sessionA2);
      expect(sessionA2.locked, isTrue);
      expect(await accounts.store.binding(profileA.id), isNull);
      expect(await accounts.store.binding(profileKey.id), isNull);
      expect(await accounts.store.binding(profileB.id), isNotNull);
      expect(await File(signOutStagePath).exists(), isFalse);
      expect(sessionB2.locked, isFalse);
      expect((await sessionB2.client.identity()).userId, bId);
      expect(
        (await sessionB2.client.chat(bOwnChatId, sessionB2.capture()))['id'],
        bOwnChatId,
      );
      outcomes['a_signout_left_b_account_usable'] = true;

      final sessionA3 = await accounts.open(
        profileA,
        email: aEmail,
        password: aPassword,
      );
      final a3Lease = sessionA3.capture();
      expect(
        (await sessionA3.client.chats(lease: a3Lease))
            .any((chat) => chat['id'] == signOutChatId),
        isTrue,
      );
      expect(await accounts.store.chat(a3Lease, signOutChatId), isNull);
      expect(await accounts.store.draft(a3Lease, signOutChatId), isNull);
      expect(await accounts.store.queue(a3Lease, signOutChatId), isEmpty);
      expect(
        (await accounts.store.stagedReferences(a3Lease))
            .contains(signOutStagePath),
        isFalse,
      );
      outcomes['explicit_signout_cleared_exact_account_partition'] = true;
      outcomes['a_reconnect_kept_server_history_after_signout'] = true;
      await sessionA3.client.deleteChat(signOutChatId, a3Lease);
      createdChats.remove(signOutChatId);
      await accounts.signOut(sessionA3);

      await sessionB2.client.deleteChat(bOwnChatId, sessionB2.capture());
      createdBChats.remove(bOwnChatId);
      await accounts.signOut(sessionB2);
      outcomes['all_required_outcomes'] = outcomes.values.every(
        (value) => value == true,
      );
      // A single redacted record is extracted from flutter drive output.
      // It contains observed consequences only, never endpoints or credentials.
      // ignore: avoid_print
      print('LIVE_ACCOUNT_ACCEPTANCE ${jsonEncode(outcomes)}');
      expect(outcomes['all_required_outcomes'], isTrue);
    } finally {
      try {
        await setRole('user');
      } on Object {
        // The outer runner independently verifies restoration.
      }
      if (apiKeyCreated) {
        try {
          await cleanupA.request('DELETE', 'api/v1/auths/api_key');
        } on Object {
          // Continue restoring the disposable server.
        }
      }
      for (final id in createdChats) {
        try {
          await cleanupA.deleteChat(
            id,
            WebUiSession(
              'cleanup-$runId',
              await cleanupA.identity(),
              cleanupA,
            ).capture(),
          );
        } on Object {
          // Only chats created by this run are candidates for cleanup.
        }
      }
      if (createdFileId != null) {
        try {
          await cleanupA.request(
            'DELETE',
            'api/v1/files/${Uri.encodeComponent(createdFileId)}',
          );
        } on Object {
          // Only the file created by this run is a cleanup candidate.
        }
      }
      if (modelRecordCreated) {
        try {
          await admin.request(
            'POST',
            'api/v1/models/model/delete',
            body: {'id': model},
          );
        } on Object {
          // The outer runner independently verifies restoration.
        }
      } else if (originalModelAccess != null) {
        try {
          await admin.request(
            'POST',
            'api/v1/models/model/access/update',
            body: {
              'id': model,
              'name': model,
              'access_grants': originalModelAccess,
            },
          );
        } on Object {
          // The outer runner independently verifies restoration.
        }
      }
      if (originalPermissions != null) {
        try {
          await admin.request(
            'POST',
            'api/v1/users/default/permissions',
            body: originalPermissions,
          );
        } on Object {
          // The outer runner independently verifies restoration.
        }
      }
      if (originalAdminConfig != null) {
        try {
          await admin.request(
            'POST',
            'api/v1/auths/admin/config',
            body: originalAdminConfig,
          );
        } on Object {
          // The outer runner independently verifies restoration.
        }
      }
      keySession?.lock();
      keySession?.client.close();
      workspaceA2?.dispose();
      workspaceA?.dispose();
      if (openedAccounts != null) {
        for (final profile in [profileA, profileB, profileKey]) {
          try {
            await openedAccounts.forgetStoredAccount(profile.id);
          } on Object {
            // Keep restoring other owned test profiles.
          }
        }
      }
      if (bootstrap != null) {
        await bootstrap.controller.shutdown();
        bootstrap.controller.dispose();
        await bootstrap.close();
      }
      if (createdBChats.isNotEmpty) {
        try {
          final cleanupBSession = WebUiSession(
            'cleanup-b-$runId',
            await cleanupB.identity(),
            cleanupB,
          );
          for (final id in createdBChats) {
            await cleanupB.deleteChat(id, cleanupBSession.capture());
          }
        } on Object {
          // Only B chats created by this run are candidates for cleanup.
        }
      }
      cleanupB.close();
      cleanupA.close();
      admin.close();
    }
  });
}
