import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../chat/transcript.dart';
import '../ollama/responses_codec.dart';
import 'accounts.dart';
import 'client.dart';
import 'conversation.dart';
import 'socket.dart';

/// Temporary responses have no saved server transcript. Keep their owner in
/// memory; the ordinary durable intent/reconciliation path cannot recover them.
final class WebUiTemporaryChat extends ChangeNotifier {
  WebUiTemporaryChat(this.session, this.socket, {required this.model});
  final WebUiSession session;
  final WebUiSocket socket;
  String model;
  String draft = '';
  String? problem, _socketId, _assistantId, _savedId;
  final nodes = <Map<String, dynamic>>[];
  final queue = <({String text, String model})>[];
  bool running = false, lost = false, queuePaused = false, saving = false;
  bool _disposed = false, _foreground = true, _terminalSeen = false;
  bool _saveAttempted = false, _dispatching = false;
  TranscriptStatus _terminalStatus = TranscriptStatus.completed;
  StreamSubscription<WebUiEvent>? _events;
  StreamSubscription<bool>? _connections;
  Timer? _silence;
  ResponsesCodec? _responses;
  String? get chatId => _socketId == null ? null : 'temporary:$_socketId';
  bool get savePending => _saveAttempted;
  bool get canSend =>
      !session.locked &&
      !lost &&
      !saving &&
      !_saveAttempted &&
      !_dispatching &&
      _socketId != null &&
      socket.sessionId == _socketId &&
      model.isNotEmpty;

  bool _initialized = false;
  bool get canSave =>
      _initialized &&
      !running &&
      !_dispatching &&
      queue.isEmpty &&
      !saving &&
      !session.locked;

  Future<void> initialize({Object? heartbeatSeconds}) async {
    if (session.identity.role != 'admin' &&
        (session.identity.permissions['chat'] as Map?)?['temporary'] == false) {
      throw const WebUiException(
        'Temporary chat is disabled for this account.',
      );
    }
    session.addListener(_accountChanged);
    socket.configureHeartbeat(heartbeatSeconds);
    await socket.connect();
    session.capture().check();
    _socketId = socket.sessionId;
    if (_socketId == null) {
      throw const WebUiException(
        'A verified live connection is required for temporary chat.',
      );
    }
    _initialized = true;
    _events = socket.events.listen(_event);
    _connections = socket.connections.listen((online) {
      if (!online || socket.sessionId != _socketId) {
        _interrupt(
          'The live connection was lost. Keep or save the visible text, then start a new temporary chat. Missing output cannot be recovered.',
        );
      }
    });
    _notify();
  }

  void _accountChanged() {
    if (session.locked) {
      _interrupt(
        'Sign in again. This temporary conversation cannot reconnect.',
      );
    }
  }

  void setDraft(String text) {
    draft = text;
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) queuePaused = true;
    _notify();
  }

  Future<bool> send(String text) async {
    if (!canSend || text.trim().isEmpty) return false;
    if (utf8.encode(text).length > 64 * 1024) {
      problem = 'Messages can be up to 64 KB.';
      _notify();
      return false;
    }
    if (running || queue.isNotEmpty) {
      queue.add((text: text, model: model));
      draft = '';
      _notify();
      return true;
    }
    return _start(text, model);
  }

  Future<bool> _start(String text, String selectedModel) async {
    final context = [
      for (final node in nodes)
        {
          'id': node['id'],
          'role': node['role'],
          'content': node['content'] ?? '',
          if (node['output'] != null) 'output': node['output'],
        },
    ];
    if (utf8.encode(jsonEncode(context)).length + utf8.encode(text).length >
        512 * 1024) {
      problem = 'This temporary conversation exceeds the 512 KB request limit. Save it and start a new chat.';
      queuePaused = true;
      _notify();
      return false;
    }
    final lease = session.capture();
    final parent = nodes.lastOrNull?['id'];
    final userId = const Uuid().v4();
    _assistantId = const Uuid().v4();
    final user = <String, dynamic>{
      'id': userId,
      'parentId': parent,
      'childrenIds': [_assistantId],
      'role': 'user',
      'content': text,
      'models': [selectedModel],
      'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
    };
    if (nodes.isNotEmpty) nodes.last['childrenIds'] = [userId];
    nodes.addAll([
      user,
      {
        'id': _assistantId,
        'parentId': userId,
        'childrenIds': <String>[],
        'role': 'assistant',
        'model': selectedModel,
        'content': '',
        'done': false,
        'timestamp': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      },
    ]);
    draft = '';
    running = true;
    _dispatching = true;
    _terminalSeen = false;
    _terminalStatus = TranscriptStatus.completed;
    _responses = ResponsesCodec(selectedModel);
    problem = null;
    _watch();
    _notify();
    try {
      final response = await session.client.dispatch({
        'stream': true,
        'model': selectedModel,
        'chat_id': chatId,
        'session_id': _socketId,
        'id': _assistantId,
        'parent_id': parent,
        'user_message': user,
        'messages': [
          ...context,
          {'role': 'user', 'content': text},
        ],
        'tools': [],
        'tool_ids': [],
        'skill_ids': [],
        'filter_ids': [],
        'features': {
          for (final key in [
            'memory',
            'web_search',
            'image_generation',
            'code_interpreter',
            'voice',
          ])
            key: false,
        },
        // In v0.11.4, a live native session otherwise injects every accessible
        // skill manifest even when skill_ids and tools are empty. Temporary
        // chat uses the server's text-only path with an explicit empty toolset.
        'params': {'function_calling': 'legacy'},
        'background_tasks': {
          'title_generation': false,
          'tags_generation': false,
          'follow_up_generation': false,
        },
      }, lease);
      final bytes = <int>[];
      await for (final part in response.stream.timeout(
        const Duration(seconds: 30),
      )) {
        lease.check();
        bytes.addAll(part);
        if (bytes.length > 1024 * 1024) {
          throw const WebUiException('Unexpected response acknowledgment.');
        }
      }
      final ack = jsonDecode(utf8.decode(bytes));
      if (ack is! Map || ack['chat_id'] != chatId || ack['status'] != true) {
        throw const WebUiException(
          'The server did not confirm this temporary request.',
        );
      }
      // An acknowledgment is not an answer. Only socket terminal + inactive
      // events include the final output after the server's outlet processing.
    } catch (error) {
      if (running) {
        _interrupt(
          'The request may have reached the server, but its live result is unavailable. $error',
        );
      }
    } finally {
      _dispatching = false;
      _notify();
      _drain();
    }
    return true;
  }

  void _event(WebUiEvent event) {
    if (_disposed ||
        session.locked ||
        event.chatId != chatId ||
        event.messageId != _assistantId ||
        nodes.isEmpty ||
        lost) {
      return;
    }
    _watch();
    final data = event.data;
    final answer = nodes.last;
    try {
      if (event.type == 'response:completion' && data is Map) {
        final type = data['type'] as String? ?? '';
        // Upstream completion is not the server's final completion.
        if (!{
          'response.completed',
          'response.failed',
          'response.incomplete',
        }.contains(type)) {
          final chunk = _responses!.accept(Map<String, dynamic>.from(data));
          if (chunk != null) {
            answer['content'] =
                (answer['content'] as String) + chunk.message.content;
            if (chunk.message.providerItems.isNotEmpty) {
              answer['output'] = chunk.message.providerItems;
            }
          }
        }
      } else if (event.type == 'chat:outlet' &&
          data is Map &&
          data['messages'] is List) {
        for (final patch in (data['messages'] as List).whereType<Map>()) {
          final target = nodes
              .where((node) => node['id'] == patch['id'])
              .firstOrNull;
          if (target == null) continue;
          final outputChanged =
              jsonEncode(patch['output']) != jsonEncode(target['output']);
          final contentChanged =
              patch['content'] is String &&
              patch['content'] != target['content'];
          if (patch['output'] is List) target['output'] = patch['output'];
          if (patch['content'] is String) {
            target['content'] = patch['content'];
            // The outlet's explicit content wins over an older output array.
            if (patch['output'] == null || (contentChanged && !outputChanged)) {
              target.remove('output');
            }
          }
        }
      } else if (event.type == 'chat:completion' && data is Map) {
        if (data['output'] is List) {
          answer['output'] = data['output'];
          answer['content'] = webUiMessageText(answer);
        }
        if (data['content'] is String) answer['content'] = data['content'];
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final delta = (choices.first as Map)['delta'];
          if (delta is Map && delta['content'] is String) {
            answer['content'] = '${answer['content']}${delta['content']}';
          }
        }
        if (data['done'] == true) _terminalSeen = true;
        if (data['error'] != null) {
          answer['error'] = data['error'];
          _terminalStatus = TranscriptStatus.failed;
        }
      } else if (event.type == 'chat:message:error') {
        answer['error'] = data is Map ? data['error'] : data;
        problem = 'The server could not finish this answer.';
        _terminalSeen = true;
        _terminalStatus = TranscriptStatus.failed;
      } else if (event.type == 'chat:tasks:cancel') {
        if (data is Map && data['output'] is List) {
          answer['output'] = data['output'];
        }
        _terminalSeen = true;
        _terminalStatus = TranscriptStatus.interrupted;
      } else if ({
        'chat:message:delta',
        'message',
        'chat:message',
        'replace',
      }.contains(event.type)) {
        final content = data is String
            ? data
            : data is Map
            ? data['content']
            : null;
        if (content is String) {
          answer['content'] =
              {'chat:message:delta', 'message'}.contains(event.type)
              ? '${answer['content']}$content'
              : content;
        }
      } else if (event.type == 'chat:active' &&
          data is Map &&
          data['active'] == false) {
        if (!_terminalSeen) {
          _interrupt(
            'The server stopped without a final answer. Missing temporary output cannot be recovered.',
          );
        } else {
          answer['done'] = true;
          answer['localStatus'] = _terminalStatus.name;
          running = false;
          _silence?.cancel();
          if (_terminalStatus != TranscriptStatus.completed) queuePaused = true;
          _drain();
        }
      }
    } catch (_) {
      _interrupt(
        'The live response could not be read. The visible partial answer is retained.',
      );
    }
    _notify();
  }

  void _watch() {
    _silence?.cancel();
    if (running) {
      _silence = Timer(
        const Duration(seconds: 90),
        () => _interrupt(
          'No live output arrived for 90 seconds. The server may still be running; this temporary result cannot be recovered.',
        ),
      );
    }
  }

  void _interrupt(String reason) {
    _silence?.cancel();
    lost = true;
    queuePaused = true;
    running = false;
    problem = reason;
    if (nodes.lastOrNull?['role'] == 'assistant' &&
        nodes.last['done'] != true) {
      nodes.last['done'] = true;
      nodes.last['localStatus'] = TranscriptStatus.interrupted.name;
      nodes.last['error'] = {'content': reason};
    }
    _notify();
  }

  void resumeQueue() {
    if (canSend) {
      queuePaused = false;
      _drain();
    }
  }

  void removeQueued(int index) {
    queue.removeAt(index);
    _notify();
  }

  void _drain() {
    if (!canSend || running || queuePaused || !_foreground || queue.isEmpty) {
      return;
    }
    final next = queue.removeAt(0);
    unawaited(
      _start(next.text, next.model).then((accepted) {
        if (!accepted) queue.insert(0, next);
        _notify();
      }),
    );
  }

  Future<void> stop() async {
    queuePaused = true;
    if (chatId == null || socket.sessionId != _socketId || session.locked) {
      return;
    }
    try {
      await session.client.stop(chatId!, session.capture());
    } catch (_) {
      _interrupt(
        'Stop could not be confirmed. The server may still be running.',
      );
    }
    _notify();
  }

  List<TranscriptMessageView> get messages => [
    for (final node in nodes)
      TranscriptMessageView(
        id: node['id'] as String,
        role: node['role'] == 'user'
            ? TranscriptRole.user
            : TranscriptRole.assistant,
        content: node['done'] == false
            ? node['content'] as String
            : webUiMessageText(node),
        status: node['done'] == false
            ? TranscriptStatus.streaming
            : TranscriptStatus.values.byName(
                node['localStatus'] as String? ?? 'completed',
              ),
      ),
  ];

  /// Explicit Save is the only path here that writes the account's chat store.
  Future<String> save(WebUiAccounts accounts) async {
    if (!canSave) {
      throw const WebUiException(
        'Stop the response and finish or remove the queue before saving.',
      );
    }
    saving = true;
    _notify();
    final lease = session.capture();
    try {
      if (_savedId == null && _saveAttempted) {
        // A lost create acknowledgment is never permission to create twice.
        for (final archived in [false, true]) {
          for (var page = 1; _savedId == null; page++) {
            final chats = await session.client.chats(
              lease: lease,
              archived: archived,
              page: page,
            );
            if (chats.isEmpty) break;
            for (final entry in chats) {
              final candidate = WebUiConversation(
                await session.client.chat(entry['id'] as String, lease),
              );
              if (nodes.isNotEmpty &&
                  candidate.nodes.containsKey(nodes.first['id'])) {
                _savedId = candidate.id;
                break;
              }
            }
          }
        }
        if (_savedId == null) {
          throw const WebUiException(
            'The previous Save could not be confirmed. Your temporary text is still here; check server history before making another copy.',
          );
        }
      }
      if (_savedId == null) {
        _saveAttempted = true;
        final created = await session.client.createChat({
          'title': 'Saved temporary chat',
          'models': [model],
          'params': {},
          'history': {
            'messages': {for (final node in nodes) node['id']: node},
            'currentId': nodes.lastOrNull?['id'],
          },
          'messages': nodes,
        }, lease);
        _savedId = created['id'] as String?;
        if (_savedId == null) {
          throw const WebUiException('The server did not confirm Save.');
        }
      }
      await accounts.store.refreshChat(session, _savedId!);
      await accounts.store.saveDraft(lease, _savedId!, {
        'text': draft,
        'model': model,
        'parentId': nodes.lastOrNull?['id'],
        'resources': <String, dynamic>{},
      });
      return _savedId!;
    } finally {
      saving = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    session.removeListener(_accountChanged);
    _silence?.cancel();
    unawaited(_events?.cancel());
    unawaited(_connections?.cancel());
    socket.dispose();
    queue.clear();
    super.dispose();
  }
}
