import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../ollama/sse.dart';
import 'client.dart';
import 'conversation.dart';
import 'socket.dart';
import 'store.dart';

enum WebUiRunState {
  prepared,
  establishing,
  dispatched,
  running,
  approval,
  uncertain,
  completed,
  failed,
  stopped,
  dismissed,
}

/// A durable intent is written before either create or completion can reach
/// the network. Recovery reads server state; it never replays a dispatch.
final class WebUiRun extends ChangeNotifier {
  WebUiRun._(this.session, this.store, this.socket, this.data) {
    _events = socket?.events.listen(_event);
    _connections = socket?.connections.listen((online) {
      // Dispatch owns the fresh handoff until it receives an acknowledgment.
      // A connection alone is not evidence that this intent reached the server.
      if (online &&
          {WebUiRunState.uncertain, WebUiRunState.running, WebUiRunState.approval}
              .contains(state)) {
        unawaited(reconcile());
      }
    });
  }
  final WebUiSession session;
  final WebUiStore store;
  final WebUiSocket? socket;
  final Map<String, dynamic> data;
  StreamSubscription<WebUiEvent>? _events;
  StreamSubscription<bool>? _connections;
  Timer? _poll, _saveTimer;
  bool _disposed = false, _reconciling = false;
  bool get terminal => {
    WebUiRunState.completed,
    WebUiRunState.failed,
    WebUiRunState.stopped,
    WebUiRunState.dismissed,
  }.contains(state);
  String get id => data['id'] as String;
  String? get chatId => data['chatId'] as String?;
  String get userId => data['userId'] as String;
  String get assistantId => data['assistantId'] as String;
  String? get parentId => data['parentId'] as String?;
  String get text => data['text'] as String;
  String get model => data['model'] as String;
  String get partial => data['partial'] as String? ?? '';
  String? get problem => data['problem'] as String?;
  WebUiRunState get state =>
      WebUiRunState.values.byName(data['state'] as String);
  Map<String, dynamic>? get answer => data['answer'] is Map
      ? Map<String, dynamic>.from(data['answer'] as Map)
      : null;
  bool get stopRequested => data['stopRequested'] == true;

  static Future<WebUiRun> prepare({
    required WebUiSession session,
    required WebUiStore store,
    WebUiSocket? socket,
    String? chatId,
    required String? expectedParentId,
    required String text,
    required String model,
    String? queueId,
    String? anchorFingerprint,
    String? revisionTargetId,
    String? revisionFingerprint,
    bool regenerate = false,
    Map<String, dynamic> resources = const {},
  }) async {
    final lease = session.capture();
    if ((text.trim().isEmpty && revisionTargetId == null) ||
        utf8.encode(text).length > 64 * 1024) {
      throw const WebUiException('Enter a message of up to 64 KB.');
    }
    if (model.isEmpty) throw const WebUiException('Select an available model.');
    final unsettled = (await store.intents(lease)).where(
      (intent) =>
          intent['chatId'] == chatId &&
          !{
            'completed',
            'failed',
            'stopped',
            'dismissed',
          }.contains(intent['state']),
    );
    if (unsettled.isNotEmpty) {
      throw const WebUiException(
        'Reconcile the previous request before sending another. Your draft is retained.',
      );
    }
    var branch = <Map<String, dynamic>>[];
    String? insertionParent = expectedParentId;
    Map<String, dynamic>? userFields;
    var requestText = text;
    var runResources = Map<String, dynamic>.of(resources);
    if (chatId != null) {
      final current = WebUiConversation(
        await store.refreshChat(session, chatId),
      );
      if (anchorFingerprint == null
          ? current.tip != expectedParentId
          : current.fingerprint(expectedParentId) != anchorFingerprint) {
        throw const WebUiException(
          'This conversation changed on the server. Refresh and review its continuation; your draft is retained.',
        );
      }
      if ((await session.client.tasks(chatId, lease)).isNotEmpty) {
        throw const WebUiException(
          'A response is already running in this conversation. Wait or stop it before sending.',
        );
      }
      if (revisionTargetId != null) {
        final target = current.nodes[revisionTargetId];
        if (target == null ||
            current.fingerprint(revisionTargetId) != revisionFingerprint) {
          throw const WebUiException(
            'This message changed on the server. Refresh before creating a version.',
          );
        }
        final user = regenerate ? current.nodes[target['parentId']] : target;
        if (user == null ||
            user['role'] != 'user' ||
            (regenerate && target['role'] != 'assistant')) {
          throw const WebUiException('This message cannot be revised.');
        }
        insertionParent = user['parentId'] as String?;
        userFields = {
          for (final key in [
            'parentId',
            'role',
            'content',
            'files',
            'models',
            'timestamp',
          ])
            if (user.containsKey(key)) key: user[key],
          if (regenerate) 'id': user['id'],
        };
        if (regenerate) {
          requestText = webUiMessageText(user);
        } else {
          userFields['content'] = text;
        }
        runResources = {...resources, 'files': user['files'] ?? []};
      }
      branch = insertionParent == null
          ? []
          : current.branch(tipId: insertionParent);
      if (branch.isNotEmpty &&
          branch.last['role'] == 'assistant' &&
          branch.last['done'] == false) {
        throw const WebUiException(
          'The previous answer is still running or waiting for approval. Review it before sending.',
        );
      }
    }
    const uuid = Uuid();
    final run = WebUiRun._(session, store, socket, {
      'id': uuid.v4(),
      'userId': userFields?['id'] ?? uuid.v4(),
      'assistantId': uuid.v4(),
      'chatId': chatId,
      'parentId': insertionParent, 'observedTipId': expectedParentId,
      'text': requestText,
      if (userFields != null) 'userFields': userFields,
      'reuseUser': regenerate,
      'model': model,
      'resources': runResources, 'state': 'prepared', 'partial': '',
      'epoch': lease.epoch,
      if (queueId != null) 'queueId': queueId, 'profileId': session.profileId,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      // This fallback inference context is not a server-history update. The
      // pinned server loads saved structured context and applies its own budget.
      'context': branch
          .skip(branch.length > 127 ? branch.length - 127 : 0)
          .map(
            (node) => {
              'role': node['role'],
              'content': node['content'] ?? '',
              if (node['output'] != null) 'output': node['output'],
              if (node['files'] != null) 'files': node['files'],
              if (node['model'] != null) 'model': node['model'],
            },
          )
          .toList(),
    });
    await run._save(lease);
    return run;
  }

  static Future<WebUiRun> restore(
    WebUiSession session,
    WebUiStore store,
    WebUiSocket? socket,
    Map<String, dynamic> data,
  ) async {
    final run = WebUiRun._(session, store, socket, Map.of(data));
    if (!run.terminal) {
      run.data['state'] = 'uncertain';
      run.data['problem'] = 'The app stopped before this request was reconciled. Check the server result before a new attempt.';
      await run._save(session.capture());
    }
    return run;
  }

  Future<void> dismissUncertainty() async {
    if (state != WebUiRunState.uncertain) return;
    await _transition(
      WebUiRunState.dismissed,
      session.capture(),
      'A fresh attempt was explicitly requested. This request may still have executed on the server.',
    );
  }

  Future<void> dispatch() async {
    if (state != WebUiRunState.prepared) {
      throw StateError('An intent can be dispatched only once.');
    }
    final lease = session.capture();
    final user = <String, dynamic>{
      'id': userId,
      'parentId': parentId,
      if (data['reuseUser'] != true) 'childrenIds': [assistantId],
      'role': 'user',
      'content': text,
      'models': [model],
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      if ((data['resources'] as Map)['files'] != null)
        'files': (data['resources'] as Map)['files'],
      if (data['userFields'] is Map)
        ...Map<String, dynamic>.from(data['userFields'] as Map),
    };
    try {
      if (chatId == null) {
        await _transition(WebUiRunState.establishing, lease);
        final created = await session.client.createChat(
          {
            'title': text
                .trim()
                .split('\n')
                .first
                .substring(
                  0,
                  text.trim().split('\n').first.length.clamp(0, 80),
                ),
            'models': [model],
            'history': {
              'messages': {userId: user},
              'currentId': userId,
            },
            'messages': [user],
            'params': {},
          },
          lease,
          folderId: (data['resources'] as Map)['folderId'] as String?,
        );
        if (created['id'] is! String) {
          throw const WebUiException(
            'The server did not confirm the new conversation.',
          );
        }
        data['chatId'] = created['id'];
        await _save(lease); // Required before the first completion request.
      }
      await _transition(WebUiRunState.dispatched, lease);
      final resources = data['resources'] as Map;
      final response = await session.client.dispatch({
        'stream': true,
        'model': model,
        'chat_id': chatId,
        'id': assistantId,
        'parent_id': parentId,
        'user_message': user,
        'messages': [
          ...(data['context'] as List),
          {'role': 'user', 'content': user['content']},
        ],
        if (socket?.sessionId != null) 'session_id': socket!.sessionId,
        for (final key in [
          'files',
          'tool_ids',
          'skill_ids',
          'features',
          'params',
        ])
          if (resources[key] != null) key: resources[key],
        'background_tasks': {
          'title_generation': false,
          'tags_generation': false,
          'follow_up_generation': false,
        },
      }, lease);
      await _transition(WebUiRunState.running, lease);
      if (response.headers['content-type']?.contains('text/event-stream') ==
          true) {
        await for (final event
            in response.stream
                .timeout(const Duration(seconds: 90))
                .transform(
                  const SseDataDecoder(
                    maxLineBytes: 2 * 1024 * 1024,
                    maxEventBytes: 4 * 1024 * 1024,
                  ),
                )) {
          lease.check();
          if (event.data == '[DONE]') continue;
          final payload = jsonDecode(event.data);
          if (payload is Map) _completion(Map<String, dynamic>.from(payload));
        }
      } else {
        final bytes = <int>[];
        await for (final part in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          lease.check();
          if (bytes.length + part.length > 4 * 1024 * 1024) {
            throw const WebUiException(
              'The response acknowledgment is too large.',
            );
          }
          bytes.addAll(part);
        }
        if (bytes.isNotEmpty) {
          final acknowledgment = jsonDecode(utf8.decode(bytes));
          if (acknowledgment is Map) {
            data['taskIds'] = acknowledgment['task_ids'] ?? [];
            if (acknowledgment['chat_id'] != null &&
                acknowledgment['chat_id'] != chatId) {
              throw const WebUiException(
                'The server acknowledged a different conversation. Refresh before continuing.',
              );
            }
            _completion(Map<String, dynamic>.from(acknowledgment));
          }
        }
      }
      await _save(lease);
      await reconcile();
    } on Object catch (error) {
      await _uncertain(error, lease);
    }
  }

  Future<void> reconcile() async {
    if (_disposed || session.locked || _reconciling) return;
    _reconciling = true;
    _poll?.cancel();
    final lease = session.capture();
    try {
      if (chatId == null) {
        await _transition(
          WebUiRunState.uncertain,
          lease,
          'The new conversation acknowledgment was lost. Locate it on the server before making a new attempt.',
        );
        return;
      }
      // The task list is read before the chat. Zero tasks alone is never a
      // terminal result; require our exact saved assistant and parent chain.
      final tasks = await session.client.tasks(chatId!, lease);
      final current = WebUiConversation(
        await store.refreshChat(session, chatId!),
      );
      final user = current.nodes[userId];
      final node = current.nodes[assistantId];
      data['taskIds'] = tasks;
      if (user != null &&
          (user['parentId'] != parentId ||
              jsonEncode(user['content']) !=
                  jsonEncode(
                    (data['userFields'] as Map?)?['content'] ?? text,
                  ))) {
        await _transition(
          WebUiRunState.uncertain,
          lease,
          'The server changed this request. Your original intent is retained; review the server conversation.',
        );
        return;
      }
      if (node != null && node['parentId'] != userId) {
        await _transition(
          WebUiRunState.uncertain,
          lease,
          'The saved answer belongs to a different continuation. Review the conversation.',
        );
        return;
      }
      if (node != null) {
        data['answer'] = node;
        final savedText = webUiMessageText(node);
        if (savedText.isNotEmpty || node['done'] == true) {
          data['partial'] = savedText;
        }
      }
      if (node != null && webUiPendingCalls(node).isNotEmpty && tasks.isEmpty) {
        await _transition(WebUiRunState.approval, lease);
      } else if (tasks.isNotEmpty) {
        await _transition(WebUiRunState.running, lease);
        _scheduleReconcile();
      } else if (user != null && node != null && node['done'] == true) {
        final output = (node['output'] as List? ?? const []).whereType<Map>();
        final cancelled = output.any((item) => item['status'] == 'cancelled');
        await _transition(
          stopRequested || cancelled
              ? WebUiRunState.stopped
              : node['error'] != null
              ? WebUiRunState.failed
              : WebUiRunState.completed,
          lease,
        );
      } else {
        await _transition(
          WebUiRunState.uncertain,
          lease,
          'The server has not confirmed this request’s final result. Check again before starting another attempt.',
        );
      }
    } on Object catch (error) {
      await _uncertain(error, lease);
    } finally {
      _reconciling = false;
    }
  }

  /// An explicit recovery read of every relevant inventory, never a resend.
  Future<void> locateCreatedChat() async {
    if (chatId != null) return reconcile();
    final lease = session.capture();
    for (final archived in [false, true]) {
      for (var page = 1; ; page++) {
        final entries = await session.client.chats(
          lease: lease,
          page: page,
          archived: archived,
        );
        if (entries.isEmpty) break;
        for (final entry in entries) {
          final candidate = WebUiConversation(
            await session.client.chat(entry['id'] as String, lease),
          );
          if (candidate.nodes.containsKey(userId)) {
            data['chatId'] = candidate.id;
            await _save(lease);
            await reconcile();
            return;
          }
        }
      }
    }
    await _transition(
      WebUiRunState.uncertain,
      lease,
      'No matching conversation was found. This does not prove that the request was never accepted.',
    );
  }

  Future<void> stop() async {
    if (chatId == null || terminal) return;
    final lease = session.capture();
    data['stopRequested'] = true;
    await _save(lease);
    try {
      await session.client.stop(chatId!, lease);
      await reconcile();
    } on Object catch (error) {
      await _uncertain(error, lease);
    }
  }

  Future<void> resolveCall(
    String callId,
    String action, {
    Object? answers,
  }) async {
    if (state != WebUiRunState.approval || chatId == null) return;
    if (!{'approve', 'reject', 'answer'}.contains(action)) {
      throw ArgumentError.value(action);
    }
    final lease = session.capture();
    // Resolution resumes the server run and is also dispatched exactly once.
    await _transition(WebUiRunState.dispatched, lease);
    try {
      await session.client.request(
        'POST',
        'api/v1/chats/${Uri.encodeComponent(chatId!)}/messages/${Uri.encodeComponent(assistantId)}/resolve',
        body: {
          'call_id': callId,
          'action': action,
          if (answers != null) 'answers': answers,
        },
        lease: lease,
      );
      await reconcile();
    } on Object catch (error) {
      await _uncertain(error, lease);
    }
  }

  void _event(WebUiEvent event) {
    if (_disposed ||
        session.locked ||
        event.chatId != chatId ||
        event.messageId != assistantId) {
      return;
    }
    final payload = event.data;
    if (event.type == 'chat:completion' ||
        event.type == 'response:completion') {
      if (payload is Map) _completion(Map<String, dynamic>.from(payload));
    } else if (event.type == 'chat:message:delta' || event.type == 'message') {
      if (payload is Map && payload['content'] is String) {
        data['partial'] = partial + (payload['content'] as String);
      }
    } else if (event.type == 'chat:message' || event.type == 'replace') {
      if (payload is Map && payload['content'] is String) {
        data['partial'] = payload['content'];
      }
    }
    // Late outlet patches and active=false always trigger an authoritative read.
    if ({
          'chat:outlet',
          'chat:active',
          'chat:tasks:cancel',
          'chat:reload',
        }.contains(event.type) ||
        payload is Map && payload['done'] == true) {
      unawaited(reconcile());
    }
    _changed();
  }

  void _completion(Map<String, dynamic> payload) {
    if (payload['output'] is List) {
      final node = <String, dynamic>{...?answer, 'output': payload['output']};
      data['answer'] = node;
      final text = webUiMessageText(node);
      if (text.isNotEmpty) data['partial'] = text;
    }
    if (payload['content'] is String) data['partial'] = payload['content'];
    final choices = payload['choices'];
    if (choices is List && choices.isNotEmpty && choices.first is Map) {
      final choice = choices.first as Map;
      final delta = choice['delta'];
      if (delta is Map && delta['content'] is String) {
        data['partial'] = partial + (delta['content'] as String);
      }
      final message = choice['message'];
      if (message is Map && message['content'] is String) {
        data['partial'] = message['content'];
      }
    }
    if (payload['error'] != null) {
      data['problem'] =
          'The server reported a generation error. Checking the saved result.';
    }
    _changed();
  }

  void _scheduleReconcile() {
    _poll?.cancel();
    if (!_disposed) {
      _poll = Timer(const Duration(seconds: 2), () => unawaited(reconcile()));
    }
  }

  void _changed() {
    if (_disposed) return;
    notifyListeners();
    _saveTimer ??= Timer(const Duration(milliseconds: 150), () {
      _saveTimer = null;
      if (!session.locked && !_disposed) {
        unawaited(_save(session.capture()).catchError((Object _) {}));
      }
    });
  }

  Future<void> _transition(
    WebUiRunState next,
    WebUiLease lease, [
    String? problem,
  ]) async {
    data['state'] = next.name;
    data['problem'] = problem;
    await _save(lease);
    if (!_disposed) notifyListeners();
  }

  Future<void> _save(WebUiLease lease) => store.saveIntent(
    lease,
    id,
    chatId ?? 'new:$id',
    Map<String, dynamic>.from(jsonDecode(jsonEncode(data)) as Map),
  );
  Future<void> _uncertain(Object error, WebUiLease lease) async {
    _poll?.cancel();
    if (_disposed || session.locked) return;
    data['state'] = 'uncertain';
    data['problem'] = error is WebUiException ? error.message : 'Connection interrupted. Your request is retained; check its server result before retrying.';
    await _save(lease);
    if (error is WebUiException && error.authenticationLost) session.lock();
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _saveTimer?.cancel();
    unawaited(_events?.cancel());
    unawaited(_connections?.cancel());
    super.dispose();
  }
}
