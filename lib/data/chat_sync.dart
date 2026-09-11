import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

final class ChatSyncState {
  const ChatSyncState({
    this.supported = false,
    this.enabled = false,
    this.pending = 0,
    this.lastSync,
    this.error,
  });
  final bool supported;
  final bool enabled;
  final int pending;
  final String? lastSync;
  final String? error;
  factory ChatSyncState.fromMap(Map<Object?, Object?> value) => ChatSyncState(
    supported: value['supported'] == true,
    enabled: value['enabled'] == true,
    pending: value['pending'] as int? ?? 0,
    lastSync: value['lastSync'] as String?,
    error: value['error'] as String?,
  );
}

final class ChatSyncChange {
  const ChatSyncChange({
    required this.token,
    required this.id,
    required this.deleted,
    required this.conflict,
    this.json,
  });
  final String token;
  final String id;
  final String? json;
  final bool deleted;
  final bool conflict;
  factory ChatSyncChange.fromMap(Map<Object?, Object?> value) => ChatSyncChange(
    token: value['token']! as String,
    id: value['id']! as String,
    json: value['json'] as String?,
    deleted: value['deleted'] == true,
    conflict: value['conflict'] == true,
  );
}

/// Thin platform adapter. CloudKit owns network scheduling and retry.
class ChatSyncBridge {
  static const configured = bool.fromEnvironment(
    'MOBILELLAMA_ICLOUD',
    defaultValue: true,
  );

  ChatSyncBridge({MethodChannel? channel, bool? supportedPlatform})
    : _channel = channel ?? const MethodChannel('app.mobollama/chat_sync'),
      _supportedPlatform = configured && (supportedPlatform ?? Platform.isIOS);
  final MethodChannel _channel;
  final bool _supportedPlatform;
  void Function()? onChanged;

  Future<ChatSyncState> initialize() async {
    if (!_supportedPlatform) return const ChatSyncState();
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'changed') onChanged?.call();
    });
    return _state('initialize');
  }

  Future<ChatSyncState> _state(String method) async => ChatSyncState.fromMap(
    await _channel.invokeMapMethod<Object?, Object?>(method) ?? const {},
  );
  Future<ChatSyncState> status() => _state('status');
  Future<ChatSyncState> enable() => _state('enable');
  Future<ChatSyncState> disable() => _state('disable');
  Future<ChatSyncState> sync() => _state('sync');
  Future<void> put(String id, {String? json, bool deleted = false}) => _channel
      .invokeMethod<void>('put', {'id': id, 'json': json, 'deleted': deleted});
  Future<ChatSyncChange?> nextChange() async {
    final value = await _channel.invokeMapMethod<Object?, Object?>(
      'nextChange',
    );
    return value == null ? null : ChatSyncChange.fromMap(value);
  }

  Future<void> acknowledge(String token) =>
      _channel.invokeMethod<void>('acknowledge', {'token': token});
  void dispose() {
    onChanged = null;
    if (_supportedPlatform) _channel.setMethodCallHandler(null);
  }
}

/// Transfers committed chats between SQLite and the native durable inbox.
/// There is no network polling: app mutations and CKSyncEngine events wake it.
final class ChatSyncService extends ChangeNotifier {
  ChatSyncService({
    required this.bridge,
    required this.source,
    required this.canRun,
    required this.revision,
    required this.setContextBusy,
    required this.localVersions,
    required this.exportChat,
    required this.applyChange,
    required this.hasReceipt,
    required this.loadBaseline,
    required this.saveBaseline,
  }) {
    source.addListener(_sourceChanged);
    bridge.onChanged = () => _schedule(force: true);
  }
  final ChatSyncBridge bridge;
  final Listenable source;
  final bool Function() canRun;
  final String Function() revision;
  final void Function(bool) setContextBusy;
  final Future<Map<String, String>> Function() localVersions;
  final Future<String> Function(String) exportChat;
  final Future<void> Function(ChatSyncChange) applyChange;
  final Future<bool> Function(String) hasReceipt;
  final Map<String, String> Function() loadBaseline;
  final Future<void> Function(Map<String, String>) saveBaseline;

  ChatSyncState state = const ChatSyncState();
  String? error;
  String? notice;
  bool working = false;
  bool _closed = false;
  bool _nativePending = false;
  bool _networkRequested = false;
  String? _lastRevision;
  Map<String, String> _baseline = {};
  Timer? _timer;
  Future<void>? _run;

  Future<void> initialize() async {
    try {
      _baseline = Map.of(loadBaseline());
      state = await bridge.initialize();
      error = state.error;
      if (state.enabled) _schedule(force: true);
    } on Object catch (failure) {
      error = _message(failure);
    }
    if (!_closed) notifyListeners();
  }

  Future<bool> setEnabled(bool value) async {
    if (working || !canRun()) return false;
    working = true;
    error = null;
    notifyListeners();
    try {
      // Commit the rebuild marker before enabling a possibly different account.
      // A crash after native enable must never restore another account's hashes.
      if (value) {
        _baseline = {};
        await saveBaseline({});
      }
      state = value ? await bridge.enable() : await bridge.disable();
      error = state.error;
      _lastRevision = null;
      return state.enabled == value;
    } on Object catch (failure) {
      error = _message(failure);
      return false;
    } finally {
      working = false;
      if (!_closed) notifyListeners();
      if (state.enabled) _schedule(force: true);
    }
  }

  void _sourceChanged() {
    if (working || _closed || !state.enabled || !canRun()) return;
    if (_nativePending || revision() != _lastRevision) _schedule();
  }

  void _schedule({bool force = false}) {
    if (_closed) return;
    _nativePending |= force;
    if (working || !state.enabled || !canRun()) return;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 300), () {
      unawaited(synchronize());
    });
  }

  Future<void> synchronize({bool network = false}) {
    _networkRequested |= network;
    _timer?.cancel();
    if (_run != null) return _run!;
    if (_closed || !state.enabled || !canRun()) return Future.value();
    final future = _perform();
    _run = future;
    return future.whenComplete(() => _run = null);
  }

  Future<void> _perform() async {
    working = true;
    error = null;
    _nativePending = false;
    notifyListeners();
    try {
      state = await bridge.status();
      if (!state.enabled) return;
      await _transferLocal();
      if (_networkRequested) {
        _networkRequested = false;
        state = await bridge.sync();
        if (canRun())
          await _transferLocal();
        else
          _nativePending = true;
      }
      state = await bridge.status();
      error = state.error;
      _lastRevision = revision();
    } on Object catch (failure) {
      error = _message(failure);
    } finally {
      working = false;
      if (!_closed) notifyListeners();
      if (error == null && (_nativePending || _networkRequested)) {
        _schedule(force: true);
      }
    }
  }

  Future<void> _transferLocal() async {
    if (!canRun()) {
      _nativePending = true;
      return;
    }
    setContextBusy(true);
    try {
      // Complete acknowledgements whose database transaction survived a restart.
      while (true) {
        final change = await bridge.nextChange();
        if (change == null || !await hasReceipt(change.token)) break;
        await _recordApplied(change);
        await bridge.acknowledge(change.token);
      }
      var versions = await localVersions();
      // Flush local edits first. The native bridge preserves them as a conflict
      // copy if a newer incoming version has not yet been applied to SQLite.
      for (final entry in versions.entries) {
        if (_baseline[entry.key] == entry.value) continue;
        await bridge.put(entry.key, json: await exportChat(entry.key));
        _baseline[entry.key] = entry.value;
      }
      for (final id in _baseline.keys.toList()) {
        if (versions.containsKey(id)) continue;
        await bridge.put(id, deleted: true);
        _baseline.remove(id);
      }
      await saveBaseline(Map.of(_baseline));
      while (true) {
        final change = await bridge.nextChange();
        if (change == null) break;
        if (!await hasReceipt(change.token)) await applyChange(change);
        await _recordApplied(change);
        await bridge.acknowledge(change.token);
        if (change.conflict) {
          notice = 'Conflicting edits were kept as a separate chat.';
          _nativePending = true; // Publish the newly retained conversation.
        }
      }
    } finally {
      setContextBusy(false);
    }
  }

  Future<void> _recordApplied(ChatSyncChange change) async {
    if (change.conflict)
      return; // A conflict copy is a new local chat to publish.
    final versions = await localVersions();
    final value = versions[change.id];
    if (value == null)
      _baseline.remove(change.id);
    else
      _baseline[change.id] = value;
    await saveBaseline(Map.of(_baseline));
  }

  static String _message(Object error) => switch (error) {
    PlatformException() => error.message ?? 'iCloud sync is unavailable.',
    FormatException() => error.message,
    _ => error.toString(),
  };

  Future<void> close() async {
    _closed = true;
    _timer?.cancel();
    source.removeListener(_sourceChanged);
    await _run;
    bridge.dispose();
  }
}
