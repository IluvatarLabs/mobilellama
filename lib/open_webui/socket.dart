import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as io;

import 'client.dart';

final class WebUiEvent {
  const WebUiEvent(
    this.chatId,
    this.messageId,
    this.type,
    this.data,
    this.reply,
  );
  final String? chatId, messageId;
  final String type;
  final Object? data;
  final void Function(Object?)? reply;
}

/// One authenticated socket per account session. The Socket.IO connection ID
/// is usable only after the server confirms the same user as the REST session.
class WebUiSocket {
  WebUiSocket(this.session);
  final WebUiSession session;
  final _events = StreamController<WebUiEvent>.broadcast();
  final _connections = StreamController<bool>.broadcast();
  io.Socket? _socket;
  String? _sessionId;
  Timer? _heartbeat;
  Duration _heartbeatInterval = const Duration(seconds: 30);
  bool _disposed = false;
  Stream<WebUiEvent> get events => _events.stream;
  Stream<bool> get connections => _connections.stream;
  String? get sessionId => session.locked ? null : _sessionId;

  void configureHeartbeat(Object? seconds) {
    if (seconds is num && seconds > 0) {
      _heartbeatInterval = Duration(milliseconds: (seconds * 1000).round());
    }
    _startHeartbeat();
  }

  void _startHeartbeat() {
    _heartbeat?.cancel();
    if (_disposed || sessionId == null) return;
    _heartbeat = Timer.periodic(_heartbeatInterval, (_) {
      if (!_disposed && sessionId != null && _socket?.connected == true) {
        _socket!.emit('heartbeat', <String, dynamic>{});
      }
    });
  }

  Future<void> connect() async {
    if (_disposed) throw StateError('Socket has been disposed.');
    final lease = session.capture();
    final token = session.client.options.apiKey;
    if (token.isEmpty) {
      throw const WebUiException('Sign in to connect live events.');
    }
    final ready = Completer<void>();
    final root = session.client.root;
    _heartbeat?.cancel();
    _socket?.dispose();
    _sessionId = null;
    final socket = _socket = io.io(
      root.origin,
      io.OptionBuilder()
          .setTransports(['websocket'])
          .setPath('${root.path}/ws/socket.io')
          .setAuth({'token': token})
          .setExtraHeaders(session.client.options.headers)
          .enableForceNew()
          .disableMultiplex()
          .disableAutoConnect()
          .build(),
    );
    socket.onConnect((_) {
      if (_disposed || session.locked) return;
      socket.emitWithAck(
        'user-join',
        {
          'auth': {'token': token},
        },
        ack: (value) {
          if (_disposed || session.locked || socket != _socket) return;
          if (value is! Map || value['id'] != lease.identity.userId) {
            socket.disconnect();
            if (!ready.isCompleted) {
              ready.completeError(
                const WebUiException(
                  'The live connection could not verify this account.',
                ),
              );
            }
            return;
          }
          _sessionId = socket.id;
          _startHeartbeat();
          _connections.add(true);
          if (!ready.isCompleted) ready.complete();
        },
      );
    });
    socket.onDisconnect((_) {
      _heartbeat?.cancel();
      _sessionId = null;
      if (!_disposed) _connections.add(false);
    });
    socket.onConnectError((_) {
      if (!ready.isCompleted) {
        ready.completeError(
          const WebUiException(
            'Live events are unavailable. Ordinary saved chat is still available.',
          ),
        );
      }
    });
    socket.on('events', (payload) {
      if (_disposed || session.locked || _sessionId == null) return;
      final arguments = payload is List ? payload : [payload];
      if (arguments.isEmpty || arguments.first is! Map) return;
      final envelope = arguments.first as Map;
      final event = envelope['data'];
      if (event is! Map || event['type'] is! String) return;
      final callback = arguments.length > 1 && arguments.last is Function
          ? arguments.last as Function
          : null;
      var replied = false;
      _events.add(
        WebUiEvent(
          envelope['chat_id'] as String?,
          envelope['message_id'] as String?,
          event['type'] as String,
          event['data'],
          callback == null
              ? null
              : (value) {
                  lease.check();
                  if (replied ||
                      _disposed ||
                      socket != _socket ||
                      !socket.connected) {
                    return;
                  }
                  replied = true;
                  callback(value);
                },
        ),
      );
    });
    socket.connect();
    try {
      await ready.future.timeout(const Duration(seconds: 12));
      lease.check();
    } on Object {
      socket.dispose();
      if (_socket == socket) _socket = null;
      rethrow;
    }
  }

  void dispose() {
    _disposed = true;
    _heartbeat?.cancel();
    _sessionId = null;
    _socket?.dispose();
    _socket = null;
    unawaited(_events.close());
    unawaited(_connections.close());
  }
}
