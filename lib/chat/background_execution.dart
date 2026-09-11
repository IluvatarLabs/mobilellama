import 'dart:io';

import 'package:flutter/services.dart';

typedef ChatBackgroundExpiration = Future<void> Function();

/// Keeps a user-started chat run executing while iOS grants finite background
/// time. This does not make the provider stream resumable.
abstract interface class ChatBackgroundExecution {
  Future<void> begin(
    String runId, {
    required ChatBackgroundExpiration onExpiration,
  });

  Future<void> end(String runId);

  Future<void> dispose();
}

/// Used where UIKit background execution is unavailable.
final class NoopChatBackgroundExecution implements ChatBackgroundExecution {
  const NoopChatBackgroundExecution();

  @override
  Future<void> begin(
    String runId, {
    required ChatBackgroundExpiration onExpiration,
  }) async {}

  @override
  Future<void> end(String runId) async {}

  @override
  Future<void> dispose() async {}
}

/// Thin adapter for the finite UIKit background task owned by the iOS runner.
final class NativeChatBackgroundExecution implements ChatBackgroundExecution {
  NativeChatBackgroundExecution({
    MethodChannel? channel,
    bool? supportedPlatform,
  }) : _channel =
           channel ??
           const MethodChannel('app.mobollama/chat_background_execution'),
       _supportedPlatform = supportedPlatform ?? Platform.isIOS {
    if (_supportedPlatform) {
      _channel.setMethodCallHandler(_handleNativeCall);
    }
  }

  final MethodChannel _channel;
  final bool _supportedPlatform;
  final Map<String, ChatBackgroundExpiration> _expirations = {};
  bool _nativeAvailable = true;
  bool _disposed = false;

  @override
  Future<void> begin(
    String runId, {
    required ChatBackgroundExpiration onExpiration,
  }) async {
    _checkRunId(runId);
    if (_disposed) {
      throw StateError('Chat background execution has been disposed.');
    }
    if (!_supportedPlatform || !_nativeAvailable) return;
    if (_expirations.containsKey(runId)) {
      throw StateError('Background execution already began for run $runId.');
    }

    _expirations[runId] = onExpiration;
    try {
      await _channel.invokeMethod<void>('begin', <String, Object>{
        'runId': runId,
      });
    } on MissingPluginException {
      _expirations.remove(runId);
      _nativeAvailable = false;
    } on PlatformException catch (error) {
      _expirations.remove(runId);
      if (error.code == 'background_unavailable') {
        // UIKit can decline a finite grant. Foreground chat remains usable.
        return;
      }
      throw ChatBackgroundExecutionException(_platformMessage(error));
    }
  }

  @override
  Future<void> end(String runId) async {
    _checkRunId(runId);
    _expirations.remove(runId);
    if (_disposed || !_supportedPlatform || !_nativeAvailable) return;
    try {
      await _channel.invokeMethod<void>('end', <String, Object>{
        'runId': runId,
      });
    } on MissingPluginException {
      _nativeAvailable = false;
    } on PlatformException catch (error) {
      throw ChatBackgroundExecutionException(_platformMessage(error));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _expirations.clear();
    if (_supportedPlatform) {
      _channel.setMethodCallHandler(null);
    }
    if (!_supportedPlatform || !_nativeAvailable) return;
    try {
      await _channel.invokeMethod<void>('dispose');
    } on MissingPluginException {
      _nativeAvailable = false;
    } on PlatformException catch (error) {
      throw ChatBackgroundExecutionException(_platformMessage(error));
    }
  }

  Future<void> _handleNativeCall(MethodCall call) async {
    if (call.method != 'expired') return;
    final arguments = call.arguments;
    if (arguments is! Map) return;
    final runId = arguments['runId'];
    if (runId is! String) return;
    final expiration = _expirations.remove(runId);
    if (expiration == null || _disposed) return;
    await expiration();
  }

  static void _checkRunId(String runId) {
    if (runId.isEmpty || runId.length > 256 || runId.trim() != runId) {
      throw ArgumentError.value(runId, 'runId', 'must be 1 to 256 characters');
    }
  }

  static String _platformMessage(PlatformException error) {
    final detail = error.message?.trim();
    return detail == null || detail.isEmpty
        ? 'Chat background execution is unavailable.'
        : 'Chat background execution is unavailable: $detail';
  }
}

final class ChatBackgroundExecutionException implements Exception {
  const ChatBackgroundExecutionException(this.message);

  final String message;

  @override
  String toString() => message;
}
