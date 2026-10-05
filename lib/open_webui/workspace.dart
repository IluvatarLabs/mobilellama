import 'dart:async';
import 'dart:convert';

import '../chat/activity_disclosure.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../chat/transcript.dart';
import 'accounts.dart';
import 'client.dart';
import 'conversation.dart';
import 'run.dart';
import 'socket.dart';
import 'resources.dart';
import 'files.dart';

/// Read model for server-owned conversations. Direct local writes, backups
/// and iCloud publication stay in the existing direct-chat controller.
final class WebUiWorkspace extends ChangeNotifier {
  WebUiWorkspace(this.accounts, this.session, {WebUiFiles? files})
    : _files = files,
      socket = WebUiSocket(session) {
    session.addListener(_sessionChanged);
  }
  final WebUiFiles? _files;
  Future<WebUiFiles> get stagedFiles async =>
      _files ?? await WebUiFiles.create();
  final WebUiAccounts accounts;
  final WebUiSession session;
  final WebUiSocket socket;
  late final WebUiResources serverResources = WebUiResources(session);
  Map<String, dynamic> serverConfiguration = {};
  void _sessionChanged() {
    if (locked) {
      queuePaused = true;
      socket.dispose();
    }
    _notify();
  }

  final List<Map<String, dynamic>> history = [], models = [];
  WebUiConversation? conversation;
  WebUiRun? run;
  String draft = '', query = '', model = '';
  String? expectedParent, error, viewTip, anchorFingerprint;
  Map<String, dynamic> resources = {};
  final Set<String> _uploadsInFlight = {};
  List<Map<String, dynamic>> get uploads =>
      (resources['uploads'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => Map<String, dynamic>.from(value))
          .toList();
  bool get attachmentsReady =>
      uploads.every((item) => item['state'] == 'ready');
  List<Map<String, dynamic>> queue = [];
  bool online = false,
      busy = false,
      archived = false,
      hasMore = false,
      queuePaused = true;
  bool _disposed = false,
      _foreground = true,
      _draining = false,
      _inventoryBusy = false;
  int scopeRevision = 0, _selection = 0, _page = 1, _visibleCount = 50;
  Timer? _draftTimer;
  Future<void> _draftWrites = Future.value();
  String get scope =>
      conversation?.id ?? run?.chatId ?? 'new:${session.profileId}';
  bool get locked => session.locked;
  bool get readOnlyConversation =>
      conversation?.envelope['user_id'] is String &&
      conversation!.envelope['user_id'] != session.identity.userId;
  bool get running =>
      run != null &&
      !run!.terminal &&
      run!.state != WebUiRunState.uncertain &&
      run!.state != WebUiRunState.approval;
  bool get needsReconciliation => run?.state == WebUiRunState.uncertain;
  String? get continuationTip =>
      anchorFingerprint != null ? expectedParent : conversation?.tip;
  bool get previewingVersion => viewTip != null && viewTip != continuationTip;
  bool get canBrowseVersions =>
      !busy &&
      !locked &&
      !running &&
      !needsReconciliation &&
      run?.state != WebUiRunState.approval &&
      queue.isEmpty;
  bool get canRevise =>
      canBrowseVersions &&
      online &&
      !readOnlyConversation &&
      conversation != null &&
      model.isNotEmpty;
  bool get diverged {
    if (conversation == null || draft.isEmpty) return false;
    if (run != null && !run!.terminal) {
      return expectedParent != run!.assistantId;
    }
    if (anchorFingerprint == null) return expectedParent != conversation!.tip;
    try {
      return conversation!.fingerprint(expectedParent) != anchorFingerprint;
    } on WebUiException {
      return true;
    }
  }

  List<String> versionsOf(String id) => conversation?.versions(id) ?? const [];

  void viewVersion(String id) {
    if (!canBrowseVersions || conversation?.nodes[id] == null) return;
    try {
      final graph = conversation!;
      final selected = continuationTip;
      final onSelected =
          selected != null &&
          graph.branch(tipId: selected).any((node) => node['id'] == id);
      final next = onSelected ? selected : graph.deepest(id);
      _detachRun();
      viewTip = next;
      _visibleCount = 50;
      _notify();
    } on Object catch (failure) {
      _failed(failure);
    }
  }

  void returnToContinuation() {
    viewTip = null;
    _visibleCount = 50;
    _notify();
  }

  Future<void> continueViewedVersion() async {
    if (!previewingVersion || !canRevise) return;
    final graph = conversation!;
    final target = viewTip!;
    final fingerprint = graph.fingerprint(target);
    busy = true;
    _notify();
    try {
      final fresh = WebUiConversation(
        await accounts.store.refreshChat(session, graph.id),
      );
      if (fresh.fingerprint(target) != fingerprint) {
        throw const WebUiException(
          'This version changed on the server. Refresh before continuing.',
        );
      }
      conversation = fresh;
      expectedParent = target;
      anchorFingerprint = fingerprint;
      viewTip = null;
      await flushDraft();
      error = null;
    } on Object catch (failure) {
      _failed(failure);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<bool> revise(String id, {String? text}) async {
    if (!canRevise) return false;
    final graph = conversation!;
    busy = true;
    error = null;
    _notify();
    try {
      await flushDraft();
      final prepared = await WebUiRun.prepare(
        session: session,
        store: accounts.store,
        socket: socket,
        chatId: graph.id,
        expectedParentId: graph.tip,
        revisionTargetId: id,
        revisionFingerprint: graph.fingerprint(id),
        regenerate: text == null,
        text: text ?? '',
        model: model,
        resources: _allowedResources(resources, model),
      );
      _detachRun();
      _attachRun(prepared);
      viewTip = null;
      anchorFingerprint = null;
      // An existing unsent draft keeps its old parent; it must be explicitly
      // moved before it can follow the newly generated version.
      if (draft.isEmpty) {
        expectedParent = prepared.assistantId;
        anchorFingerprint = null;
      }
      unawaited(prepared.dispatch().then((_) => _runChanged()));
      return true;
    } on Object catch (failure) {
      _failed(failure);
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  Map<String, dynamic>? get selectedModel =>
      models.where((item) => item['id'] == model).firstOrNull;
  Map get modelCapabilities =>
      ((selectedModel?['info'] as Map?)?['meta'] as Map?)?['capabilities']
          as Map? ??
      {};
  bool get uploadsAvailable =>
      !locked &&
      (session.identity.role == 'admin' ||
          (session.identity.permissions['chat'] as Map?)?['file_upload'] !=
              false) &&
      modelCapabilities['file_upload'] != false;
  bool get foldersAvailable =>
      (serverConfiguration['features'] as Map?)?['enable_folders'] != false &&
      (session.identity.role == 'admin' ||
          (session.identity.permissions['features'] as Map?)?['folders'] !=
              false);
  bool get visionAvailable => modelCapabilities['vision'] != false;
  Map<String, dynamic> _allowedResources(
    Map<String, dynamic> value,
    String modelId,
  ) {
    final selected = models.where((item) => item['id'] == modelId).firstOrNull;
    return {
      ...value,
      if (value['features'] is Map)
        'features': {
          for (final entry in (value['features'] as Map).entries)
            entry.key:
                entry.value == true &&
                serverResources.supportsFeature(
                  serverConfiguration,
                  selected,
                  entry.key as String,
                ),
        },
    };
  }

  Map<String, dynamic> messageNode(String id) =>
      id == run?.assistantId && run?.answer != null
      ? run!.answer!
      : conversation?.nodes[id] ?? const {};

  bool get canSend =>
      !locked &&
      !readOnlyConversation &&
      !busy &&
      online &&
      model.isNotEmpty &&
      attachmentsReady &&
      !diverged &&
      !previewingVersion &&
      (!running || run?.chatId != null) &&
      !needsReconciliation &&
      run?.state != WebUiRunState.approval;

  Future<void> initialize() async {
    final lease = session.capture();
    history.addAll(await accounts.store.chats(lease));
    await _restoreDraft();
    scopeRevision++;
    _notify();
    unawaited(socket.connect().catchError((Object _) {}));
    await Future.wait([
      refresh(),
      () async {
        try {
          serverConfiguration = await serverResources.configuration();
          socket.configureHeartbeat(
            (serverConfiguration['features']
                as Map?)?['websocket_heartbeat_interval'],
          );
        } on Object {
          /* Optional capability discovery does not prevent ordinary chat. */
        }
      }(),
      () async {
        try {
          final available = await session.client.models(lease: lease);
          lease.check();
          models
            ..clear()
            ..addAll(available);
          if (!models.any((item) => item['id'] == model)) {
            model = models.firstOrNull?['id'] as String? ?? '';
          }
        } on Object catch (failure) {
          _failed(failure);
        }
      }(),
    ]);
    resources = _allowedResources(resources, model);
    await flushDraft();
    // Restored requests always require reconciliation; reconnect never sends.
    final pending = (await accounts.store.intents(lease))
        .where(
          (item) =>
              item['chatId'] == null &&
              item['profileId'] == session.profileId &&
              !{
                'completed',
                'failed',
                'stopped',
                'dismissed',
              }.contains(item['state']),
        )
        .firstOrNull;
    if (pending != null) {
      _attachRun(
        await WebUiRun.restore(session, accounts.store, socket, pending),
      );
    }
    _notify();
    if (!locked) unawaited(synchronizeInventory());
  }

  Future<void> synchronizeInventory() async {
    if (locked || _inventoryBusy) return;
    _inventoryBusy = true;
    final lease = session.capture();
    try {
      final before = await accounts.store.inventorySnapshot(lease);
      final present = <String>{};
      for (final archivedView in [false, true]) {
        final viewIds = <String>{};
        for (var page = 1; ; page++) {
          final entries = await session.client.chats(
            lease: lease,
            archived: archivedView,
            page: page,
          );
          if (entries.isEmpty) break;
          final ids = entries.map((entry) => entry['id'] as String).toSet();
          if (ids.difference(viewIds).isEmpty) {
            throw const WebUiException(
              'The server repeated a history page. Cached history was retained.',
            );
          }
          viewIds.addAll(ids);
          present.addAll(ids);
        }
      }
      await accounts.store.finishInventory(lease, before, present);
    } on Object catch (failure) {
      if (failure is WebUiException && failure.authenticationLost) {
        _failed(failure);
      } else if (!_disposed)
        error = 'Some history could not be refreshed. Cached conversations have been retained.';
    } finally {
      _inventoryBusy = false;
      _notify();
    }
  }

  Future<void> refresh({bool more = false}) async {
    if (locked) return;
    final lease = session.capture();
    try {
      final page = more ? _page + 1 : 1;
      final entries = await session.client.chats(
        lease: lease,
        page: page,
        archived: archived,
        query: query.isEmpty ? null : query,
      );
      await accounts.store.cacheSummaries(lease, entries);
      lease.check();
      if (!more) history.clear();
      for (final item in entries) {
        history.removeWhere((old) => old['id'] == item['id']);
        history.add(item);
      }
      hasMore = entries.length >= 60;
      _page = page;
      online = true;
      error = null;
    } on Object catch (failure) {
      _failed(failure);
    }
    _notify();
  }

  Future<void> search(String value, {bool? showArchived}) async {
    query = value.trim();
    archived = showArchived ?? archived;
    await refresh();
  }

  Future<void> open(String? id) async {
    if (locked || busy) return;
    await flushDraft();
    final operation = ++_selection;
    _visibleCount = 50;
    final lease = session.capture();
    busy = true;
    error = null;
    _detachRun();
    conversation = null;
    draft = '';
    resources = {};
    expectedParent = null;
    anchorFingerprint = null;
    viewTip = null;
    try {
      if (id != null) {
        final cached = await accounts.store.chat(lease, id);
        if (cached != null && cached['complete'] == true) {
          conversation = WebUiConversation(cached);
        }
        try {
          final fresh = await accounts.store.refreshChat(session, id);
          if (operation != _selection) return;
          conversation = WebUiConversation(fresh);
          online = true;
        } on Object catch (failure) {
          _failed(failure);
        }
        if (conversation == null) {
          throw const WebUiException(
            'This chat has not been cached. Connect to open it.',
          );
        }
      }
      lease.check();
      if (operation != _selection) return;
      await _restoreDraft();
      final pending = (await accounts.store.intents(lease))
          .where(
            (item) =>
                item['chatId'] == id &&
                item['profileId'] == session.profileId &&
                !{
                  'completed',
                  'failed',
                  'stopped',
                  'dismissed',
                }.contains(item['state']),
          )
          .firstOrNull;
      if (pending != null) {
        _attachRun(
          await WebUiRun.restore(session, accounts.store, socket, pending),
        );
        if (online) unawaited(run!.reconcile());
      }
      queuePaused = true;
      queue = await accounts.store.queue(lease, scope);
      scopeRevision++;
    } on Object catch (failure) {
      _failed(failure);
    } finally {
      busy = false;
      _notify();
    }
  }

  Future<void> refreshConversation() async {
    if (conversation == null || locked) return;
    final id = conversation!.id;
    try {
      final fresh = await accounts.store.refreshChat(session, id);
      if (_disposed || conversation?.id != id) return;
      conversation = WebUiConversation(fresh);
      online = true;
      if (draft.isEmpty && anchorFingerprint == null) {
        expectedParent = conversation!.tip;
      }
    } on Object catch (failure) {
      _failed(failure);
    }
    _notify();
  }

  Future<void> _restoreDraft() async {
    final saved = await accounts.store.draft(session.capture(), scope);
    draft = saved?['text'] as String? ?? '';
    resources = Map<String, dynamic>.from(
      saved?['resources'] as Map? ?? const {},
    );
    expectedParent = saved != null && saved.containsKey('parentId')
        ? saved['parentId'] as String?
        : conversation?.tip;
    anchorFingerprint = saved?['anchorFingerprint'] as String?;
    if (saved?['model'] is String) model = saved!['model'] as String;
    if (models.isNotEmpty) resources = _allowedResources(resources, model);
  }

  void setDraft(String text) {
    if (locked || text == draft) return;
    if (draft.isEmpty) {
      if (run != null && !run!.terminal) {
        expectedParent = run!.assistantId;
        anchorFingerprint = null;
      } else {
        expectedParent = continuationTip;
      }
    }
    draft = text;
    _draftTimer?.cancel();
    _draftTimer = Timer(
      const Duration(milliseconds: 200),
      () => unawaited(flushDraft()),
    );
    _notify();
  }

  Future<void> flushDraft() async {
    _draftTimer?.cancel();
    if (locked) return;
    final lease = session.capture();
    final capturedScope = scope;
    final value = {
      'text': draft,
      'resources': Map.of(resources),
      'parentId': expectedParent,
      'anchorFingerprint': anchorFingerprint,
      'model': model,
    };
    _draftWrites = _draftWrites
        .catchError((Object _) {})
        .then((_) => accounts.store.saveDraft(lease, capturedScope, value));
    try {
      await _draftWrites;
    } on Object catch (failure) {
      _failed(failure);
    }
  }

  Future<void> adoptContinuation() async {
    await refreshConversation();
    if (!online || locked) return;
    expectedParent = conversation?.tip;
    anchorFingerprint = null;
    viewTip = null;
    await flushDraft();
    _notify();
  }

  Future<void> setDraftFolder(String? id, String? name) async {
    if (locked || conversation != null || running) return;
    resources = {...resources}
      ..remove('folderId')
      ..remove('folderName');
    if (id != null) resources.addAll({'folderId': id, 'folderName': name});
    await flushDraft();
    _notify();
  }

  Future<void> selectModel(String value) async {
    model = value;
    resources = _allowedResources(resources, value);
    await flushDraft();
    _notify();
  }

  Future<void> setResource(
    WebUiResourceKind kind,
    Map<String, dynamic> item,
    bool selected,
  ) async {
    if (locked) return;
    final selectedScope = scope;
    final selection = _selection;
    if (kind == WebUiResourceKind.skills || kind == WebUiResourceKind.tools) {
      final key = kind == WebUiResourceKind.skills ? 'skill_ids' : 'tool_ids';
      final ids = List<String>.from(resources[key] as List? ?? []);
      ids.remove(item['id']);
      if (selected && item['is_active'] != false) ids.add(item['id'] as String);
      resources = {...resources, key: ids};
    } else {
      final files = (resources['files'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      files.removeWhere((file) => file['id'] == item['id']);
      if (selected) {
        if (kind == WebUiResourceKind.files) {
          final status = await serverResources.processingStatus(
            item['id'] as String,
          );
          if (selectedScope != scope || selection != _selection || locked) {
            return;
          }
          if (status != 'completed') {
            throw const WebUiException(
              'This file is still processing or processing failed. Choose a ready file or retry processing before sending.',
            );
          }
        }
        final reference = WebUiResources.reference(kind, item);
        if ((reference['content_type'] as String? ?? '').startsWith('image/')) {
          reference['type'] = 'image';
          reference['url'] = session.client
              .endpoint(
                'api/v1/files/${Uri.encodeComponent(item['id'] as String)}/content',
              )
              .toString();
        }
        files.add(reference);
      }
      resources = {...resources, 'files': files};
    }
    await flushDraft();
    _notify();
  }

  Future<void> setFeature(String feature, bool enabled) async {
    resources = {
      ...resources,
      'features': {...?resources['features'] as Map?, feature: enabled},
    };
    await flushDraft();
    _notify();
  }

  Future<void> setToolApproval(bool ask) async {
    resources = {
      ...resources,
      'params': {
        ...?resources['params'] as Map?,
        'tool_approval_mode': ask ? 'ask' : 'full',
      },
    };
    await flushDraft();
    _notify();
  }

  Future<void> addFile(String name, List<int> bytes) async {
    final lease = session.capture();
    final target = scope;
    final files = await stagedFiles;
    final entry = await files.stage(lease, name, bytes);
    if (scope != target) {
      await files.discard(lease, entry['path'] as String);
      throw const WebUiException(
        'The destination changed. Add the file to the intended chat.',
      );
    }
    resources = {
      ...resources,
      'uploads': [...uploads, entry],
    };
    await flushDraft();
    _notify();
    unawaited(uploadFile(entry, target: target));
  }

  Future<void> _updateUpload(String target, Map<String, dynamic> entry) async {
    final lease = session.capture();
    void update(Map<String, dynamic> value) {
      final items = (value['uploads'] as List? ?? [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final index = items.indexWhere(
        (item) => item['localId'] == entry['localId'],
      );
      if (index < 0) {
        return; // The user removed this attachment while it was uploading.
      }
      items[index] = entry;
      value['uploads'] = items;
      final files = List<dynamic>.from(value['files'] as List? ?? []);
      if (entry['state'] == 'ready' && entry['reference'] is Map) {
        files.removeWhere(
          (item) => item is Map && item['id'] == entry['remoteId'],
        );
        files.add(entry['reference']);
        value['files'] = files;
      }
    }

    if (scope == target) {
      final value = Map<String, dynamic>.from(resources);
      update(value);
      resources = value;
      await flushDraft();
      _notify();
    } else {
      // Serialize the read/merge/write with ordinary draft saves. Reopening the
      // same chat waits for this tail before restoring its selected resources.
      _draftWrites = _draftWrites.catchError((Object _) {}).then((_) async {
        final saved = await accounts.store.draft(lease, target);
        if (saved == null) return;
        final value = Map<String, dynamic>.from(
          saved['resources'] as Map? ?? {},
        );
        update(value);
        await accounts.store.saveDraft(lease, target, {
          ...saved,
          'resources': value,
        });
      });
      await _draftWrites;
    }
  }

  Future<void> uploadFile(
    Map<String, dynamic> original, {
    String? target,
  }) async {
    final id = original['localId'] as String;
    if (locked || !_uploadsInFlight.add(id)) return;
    target ??= scope;
    final lease = session.capture();
    var entry = Map<String, dynamic>.from(original);
    try {
      if (entry['remoteId'] == null) {
        entry = {...entry, 'state': 'uploading', 'error': null};
        await _updateUpload(target, entry);
        final bytes = await (await stagedFiles).read(
          lease,
          entry['path'] as String,
        );
        final file = await session.client.upload(
          entry['name'] as String,
          bytes,
          entry['mime'] as String,
          lease,
        );
        if (file['id'] is! String) {
          throw const WebUiException(
            'The server did not confirm the uploaded file.',
          );
        }
        final reference = WebUiResources.reference(
          WebUiResourceKind.files,
          file,
        );
        if ((entry['mime'] as String).startsWith('image/')) {
          reference['type'] = 'image';
          reference['url'] = session.client
              .endpoint(
                'api/v1/files/${Uri.encodeComponent(file['id'] as String)}/content',
              )
              .toString();
          reference['content_type'] = entry['mime'];
        }
        entry = {
          ...entry,
          'remoteId': file['id'],
          'reference': reference,
          'state': 'processing',
        };
        await _updateUpload(target, entry);
      } else if (entry['state'] == 'failed') {
        await session.client.request(
          'POST',
          'api/v1/retrieval/process/file',
          body: {'file_id': entry['remoteId']},
          lease: lease,
        );
      }
      for (var attempt = 0; attempt < 60; attempt++) {
        final status = await serverResources.processingStatus(
          entry['remoteId'] as String,
        );
        lease.check();
        if (status == 'completed') {
          await _updateUpload(target, {
            ...entry,
            'state': 'ready',
            'error': null,
          });
          return;
        }
        if (status == 'failed' || status == 'not_found') {
          throw const WebUiException(
            'The server could not prepare this file. Your question is retained. Retry processing or remove the attachment.',
          );
        }
        await _updateUpload(target, {...entry, 'state': 'processing'});
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      await _updateUpload(target, {
        ...entry,
        'state': 'processing',
        'error': 'Still processing. Check again when the server is ready.',
      });
    } on Object catch (failure) {
      if (!locked && !_disposed) {
        await _updateUpload(target, {
          ...entry,
          'state': 'failed',
          'error': failure is WebUiException ? failure.message : 'Upload was interrupted. A server copy may exist; choose it from Server files or retry.',
        });
      }
    } finally {
      _uploadsInFlight.remove(id);
      _notify();
    }
  }

  Future<void> removeUpload(String id) async {
    final removed = uploads.where((item) => item['localId'] == id).firstOrNull;
    resources = {
      ...resources,
      'uploads': uploads.where((item) => item['localId'] != id).toList(),
      'files': (resources['files'] as List? ?? [])
          .where((item) => item is! Map || item['id'] != removed?['remoteId'])
          .toList(),
    };
    await flushDraft();
    if (removed?['path'] is String) {
      await (await stagedFiles).discard(
        session.capture(),
        removed!['path'] as String,
      );
    }
    _notify();
  }

  Future<bool> send(String text) async {
    if (!canSend) return false;
    if (running) {
      if (queue.isEmpty) queuePaused = false;
      final item = {
        'id': const Uuid().v4(),
        'text': text,
        'model': model,
        'resources': Map.of(resources),
        'createdAt': DateTime.now().toUtc().toIso8601String(),
      };
      await accounts.store.saveQueued(
        session.capture(),
        item['id'] as String,
        run!.chatId ?? scope,
        item,
      );
      queue = await accounts.store.queue(
        session.capture(),
        run!.chatId ?? scope,
      );
      draft = '';
      await flushDraft();
      _notify();
      return true;
    }
    return _start(text, resources: resources);
  }

  Future<bool> _start(
    String text, {
    required Map<String, dynamic> resources,
    String? queueId,
    String? selectedModel,
  }) async {
    busy = true;
    error = null;
    _notify();
    final selectedScope = scope;
    try {
      await flushDraft();
      final prepared = await WebUiRun.prepare(
        session: session,
        store: accounts.store,
        socket: socket,
        chatId: conversation?.id,
        expectedParentId: expectedParent,
        anchorFingerprint: anchorFingerprint,
        text: text,
        model: selectedModel ?? model,
        resources: _allowedResources(resources, selectedModel ?? model),
        queueId: queueId,
      );
      _detachRun();
      _attachRun(prepared);
      draft = '';
      expectedParent = prepared.assistantId;
      anchorFingerprint = null;
      viewTip = null;
      await accounts.store.saveDraft(session.capture(), selectedScope, {
        'text': '',
        'parentId': expectedParent,
        'resources': Map<String, dynamic>.from(resources),
        'model': model,
      });
      unawaited(prepared.dispatch().then((_) => _runChanged()));
      return true;
    } on Object catch (failure) {
      _failed(failure);
      return false;
    } finally {
      busy = false;
      _notify();
    }
  }

  void _attachRun(WebUiRun value) {
    run = value;
    value.addListener(_runChanged);
  }

  void _detachRun() {
    run?.removeListener(_runChanged);
    run?.dispose();
    run = null;
  }

  void _runChanged() {
    if (_disposed) return;
    if (run?.state == WebUiRunState.uncertain ||
        run?.state == WebUiRunState.failed ||
        run?.state == WebUiRunState.stopped ||
        locked) {
      queuePaused = true;
    }
    _notify();
    if (run?.state == WebUiRunState.completed) unawaited(_afterRun());
  }

  Future<void> _afterRun() async {
    if (_draining || locked || _disposed || run?.chatId == null) return;
    _draining = true;
    final completed = run!;
    try {
      final cached = await accounts.store.chat(
        session.capture(),
        completed.chatId!,
      );
      if (_disposed || run != completed) return;
      if (cached != null) conversation = WebUiConversation(cached);
      if (draft.isEmpty) {
        expectedParent = conversation?.tip;
        anchorFingerprint = null;
        viewTip = null;
      }
      final queueId = completed.data['queueId'];
      if (queueId is String) {
        await accounts.store.removeQueued(session.capture(), queueId);
      }
      queue = await accounts.store.queue(session.capture(), scope);
      await refresh();
      if (!_disposed &&
          _foreground &&
          !queuePaused &&
          run == completed &&
          queue.isNotEmpty) {
        final next = queue.first;
        if (next['intentId'] != null) {
          queuePaused = true;
          return;
        }
        await _start(
          next['text'] as String,
          resources: Map<String, dynamic>.from(next['resources'] as Map? ?? {}),
          queueId: next['id'] as String,
          selectedModel: next['model'] as String?,
        );
      }
    } on Object catch (failure) {
      _failed(failure);
    } finally {
      _draining = false;
      _notify();
    }
  }

  Future<void> resumeQueue() async {
    if (locked || !online || needsReconciliation) return;
    queue = await accounts.store.queue(session.capture(), scope);
    if (queue.isEmpty) return;
    final next = queue.first;
    final linked = next['intentId'];
    if (linked is String) {
      final saved = (await accounts.store.intents(session.capture()))
          .where((item) => item['id'] == linked)
          .firstOrNull;
      if (saved == null) {
        error = 'This queued prompt has an unresolved request. Review it before making another attempt.';
        queuePaused = true;
      } else {
        _detachRun();
        _attachRun(
          await WebUiRun.restore(session, accounts.store, socket, saved),
        );
        queuePaused = false;
        await run!.reconcile();
        if (run?.state == WebUiRunState.completed) {
          await _afterRun();
        } else {
          queuePaused = true;
          error = 'The queued request needs review. Remove it from the queue after reviewing its result, then resume the remaining prompts.';
        }
      }
    } else {
      queuePaused = false;
      if (!running) {
        await _start(
          next['text'] as String,
          resources: Map<String, dynamic>.from(next['resources'] as Map? ?? {}),
          queueId: next['id'] as String,
          selectedModel: next['model'] as String?,
        );
      }
    }
    _notify();
  }

  /// Explicit recovery creates a new draft only. The prior intent and partial
  /// result remain stored, and neither chat creation nor inference is replayed.
  Future<void> prepareFreshAttempt() async {
    final prior = run;
    if (prior == null || !needsReconciliation || locked) return;
    if (prior.chatId == null) {
      await prior.locateCreatedChat();
    } else {
      await prior.reconcile();
    }
    if (prior.state != WebUiRunState.uncertain) return;
    await flushDraft();
    final saved = await accounts.store.draft(
      session.capture(),
      'new:${session.profileId}',
    );
    if ((saved?['text'] as String? ?? '').isNotEmpty ||
        (saved?['resources'] as Map? ?? {}).isNotEmpty) {
      error = 'There is an unsent new-chat draft. Save or clear it before preparing a fresh attempt.';
      _notify();
      return;
    }
    final text = prior.text;
    final selected = Map<String, dynamic>.from(prior.data['resources'] as Map);
    final selectedModel = prior.model;
    await prior.dismissUncertainty();
    await open(null);
    draft = text;
    resources = selected;
    model = selectedModel;
    expectedParent = null;
    queuePaused = true;
    await flushDraft();
    scopeRevision++;
    _notify();
  }

  Future<void> removeQueued(String id) async {
    final item = queue.where((item) => item['id'] == id).firstOrNull;
    if (item == null) return;
    final intent = (await accounts.store.intents(session.capture()))
        .where((entry) => entry['id'] == item['intentId'])
        .firstOrNull;
    if (intent != null &&
        !{'completed', 'failed', 'stopped'}.contains(intent['state'])) {
      error = 'Check the saved result or stop this response before removing it from the queue.';
      _notify();
      return;
    }
    await accounts.store.removeQueued(session.capture(), id);
    queue = await accounts.store.queue(session.capture(), scope);
    _notify();
  }

  Future<void> editQueued(String id, String text) async {
    final item = queue.where((item) => item['id'] == id).firstOrNull;
    if (item == null || item['intentId'] != null || text.trim().isEmpty) return;
    await accounts.store.saveQueued(session.capture(), id, scope, {
      ...item,
      'text': text,
    });
    queue = await accounts.store.queue(session.capture(), scope);
    _notify();
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      queuePaused = true;
      unawaited(flushDraft());
    } else if (!locked) {
      unawaited(run?.reconcile());
    }
  }

  Future<void> mutate(String id, String action, {String? title}) async {
    final lease = session.capture();
    busy = true;
    _notify();
    try {
      await accounts.store.refreshChat(session, id);
      if (action == 'delete') {
        if ((await session.client.tasks(id, lease)).isNotEmpty) {
          throw const WebUiException(
            'Stop the active response before deleting this conversation.',
          );
        }
        await session.client.deleteChat(id, lease);
        await accounts.store.removeChat(lease, id);
        if (conversation?.id == id) {
          _detachRun();
          conversation = null;
          draft = '';
          resources = {};
          expectedParent = null;
          anchorFingerprint = null;
          viewTip = null;
          scopeRevision++;
        }
      } else {
        if (action == 'rename') {
          await session.client.rename(id, title!, lease);
        } else {
          await session.client.toggle(id, action, lease);
        }
        await accounts.store.refreshChat(session, id);
      }
      await refresh();
      if (conversation?.id == id) await refreshConversation();
    } on Object catch (failure) {
      _failed(failure);
    } finally {
      busy = false;
      _notify();
    }
  }

  bool get hasOlder => _allMessages.length > _visibleCount;
  Future<void> loadOlder() async {
    _visibleCount += 50;
    _notify();
  }

  void revealBranch() {
    _visibleCount = 1 << 30;
    _notify();
  }

  List<TranscriptMessageView> get messages {
    final all = _allMessages;
    return all.skip((all.length - _visibleCount).clamp(0, all.length)).toList();
  }

  List<TranscriptMessageView> get _allMessages {
    var nodes =
        conversation?.branch(tipId: viewTip ?? continuationTip) ??
        <Map<String, dynamic>>[];
    final current = run;
    if (!previewingVersion &&
        current != null &&
        (current.chatId == conversation?.id || conversation == null) &&
        (!current.terminal ||
            !nodes.any((node) => node['id'] == current.assistantId))) {
      nodes = current.parentId == null
          ? []
          : conversation?.branch(tipId: current.parentId) ?? [];
      nodes.add({
        ...?current.data['userFields'] as Map?,
        'id': current.userId,
        'role': 'user',
        'content':
            (current.data['userFields'] as Map?)?['content'] ?? current.text,
      });
      nodes.add({
        ...?current.answer,
        'id': current.assistantId,
        'role': 'assistant',
        'content': current.partial,
        'done': current.terminal,
      });
    }
    return nodes
        .where((node) => {'user', 'assistant', 'system'}.contains(node['role']))
        .map(
          (node) => TranscriptMessageView(
            id: node['id'] as String,
            role: node['role'] == 'user'
                ? TranscriptRole.user
                : TranscriptRole.assistant,
            content: webUiMessageText(node),
            canEdit: canRevise && node['role'] == 'user',
            canRegenerate:
                canRevise &&
                node['role'] == 'assistant' &&
                node['done'] != false,
            status: node['done'] == false
                ? TranscriptStatus.streaming
                : TranscriptStatus.completed,
            sources: WebUiResources.sources(node),
            toolCalls: _toolActivity(node),
          ),
        )
        .toList();
  }

  List<ToolActivityView> _toolActivity(Map node) {
    final output = (node['output'] as List? ?? []).whereType<Map>().toList();
    return [
      for (final call in output.where(
        (item) => item['type'] == 'function_call',
      ))
        () {
          final result = output
              .where(
                (item) =>
                    item['type'] == 'function_call_output' &&
                    item['call_id'] == (call['call_id'] ?? call['id']),
              )
              .firstOrNull;
          final status = result?['status'] ?? call['status'];
          return ToolActivityView(
            label: (call['name'] ?? 'Server tool').toString(),
            state: status == 'failed' || result?['error'] != null
                ? ToolActivityState.failed
                : status == 'completed'
                ? ToolActivityState.succeeded
                : status == 'in_progress'
                ? ToolActivityState.running
                : ToolActivityState.pending,
            detail: const JsonEncoder.withIndent('  ').convert({
              'arguments': call['arguments'],
              if (result != null) 'result': result['output'],
              if (status != null) 'status': status,
            }),
          );
        }(),
    ];
  }

  void _failed(Object failure) {
    if (_disposed) return;
    if (failure is! WebUiException ||
        failure.status == 401 ||
        (failure.status ?? 0) >= 500) {
      online = false;
    }
    queuePaused = true;
    error = failure is WebUiException ? failure.message : 'The server could not be reached. Cached chats and your draft are retained.';
    if (failure is WebUiException && failure.authenticationLost) {
      session.lock();
      socket.dispose();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_sessionChanged);
    _draftTimer?.cancel();
    _detachRun();
    socket.dispose();
    session.lock();
    session.client.close();
    super.dispose();
  }
}
