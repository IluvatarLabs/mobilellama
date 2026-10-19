import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:flutter/foundation.dart';

import '../data/settings_store.dart';
import '../ollama/connection_options.dart';

final class WebUiException implements Exception {
  const WebUiException(this.message, {this.status});
  final String message;
  final int? status;
  bool get authenticationLost => status == 401;
  @override
  String toString() => message;
}

final class WebUiIdentity {
  WebUiIdentity({
    required this.server,
    required this.userId,
    required this.name,
    required this.permissions,
    this.role = 'user',
  });
  final String server, userId, name;
  final Map<String, dynamic> permissions;
  final String role;
  factory WebUiIdentity.fromJson(String server, Map<String, dynamic> json) {
    final id = json['id'];
    if (id is! String || id.isEmpty) {
      throw const WebUiException(
        'The server did not return an account identity. Shared chats are unavailable.',
      );
    }
    return WebUiIdentity(
      server: server,
      userId: id,
      name: json['name'] as String? ?? 'Account',
      role: json['role'] as String? ?? 'user',
      permissions: Map<String, dynamic>.from(
        json['permissions'] as Map? ?? const {},
      ),
    );
  }
}

/// A lease expires immediately on sign-out, credential expiry or account change.
/// The account partition is server + returned user ID, never a token hash.
final class WebUiSession extends ChangeNotifier {
  WebUiSession(this.profileId, this.identity, this.client);
  final String profileId;
  final WebUiIdentity identity;
  final OpenWebUiClient client;
  int _epoch = 0;
  bool _locked = false;
  bool get locked => _locked;
  WebUiLease capture() {
    check(_epoch);
    return WebUiLease(this, _epoch);
  }

  void lock() {
    if (_locked) return;
    _epoch++;
    _locked = true;
    notifyListeners();
  }

  void check(int epoch) {
    if (_locked || epoch != _epoch) {
      throw const WebUiException('Sign in again to access this account.');
    }
  }
}

final class WebUiLease {
  const WebUiLease(this.session, this.epoch);
  final WebUiSession session;
  final int epoch;
  WebUiIdentity get identity => session.identity;
  void check() => session.check(epoch);
}

/// Open WebUI v0.11.4 REST contract. Mutations are dispatched once; uncertain
/// delivery is reconciled by the run owner, never retried by this transport.
final class OpenWebUiClient {
  OpenWebUiClient({
    required String baseUrl,
    required this.options,
    http.Client? client,
  }) : root = canonicalRoot(baseUrl),
       _client = client ?? http.Client();
  final Uri root;
  final ConnectionOptions options;
  final http.Client _client;
  String get serverId => root.toString();

  static Uri canonicalRoot(String value) {
    final uri = Uri.tryParse(value.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException(
        'Enter the server HTTP(S) address without credentials, query parameters, or a fragment.',
      );
    }
    return uri.replace(path: uri.path.replaceFirst(RegExp(r'/+$'), ''));
  }

  Uri endpoint(String relative, [Map<String, String>? query]) => root.replace(
    pathSegments: [
      ...root.pathSegments.where((segment) => segment.isNotEmpty),
      ...relative.split('/').map(Uri.decodeComponent),
    ],
    queryParameters: query,
  );

  OpenWebUiClient withToken(String token) => OpenWebUiClient(
    baseUrl: serverId,
    options: ConnectionOptions(
      authentication: ServerAuthentication.bearer,
      apiKey: token,
      customHeaders: options.customHeaders,
    ),
  );

  Future<Map<String, dynamic>> signIn(String email, String password) async =>
      _object(
        await request(
          'POST',
          'api/v1/auths/signin',
          body: {'email': email.trim(), 'password': password},
        ),
      );
  Future<WebUiIdentity> identity() async => WebUiIdentity.fromJson(
    serverId,
    _object(await request('GET', 'api/v1/auths/')),
  );
  Future<List<Map<String, dynamic>>> models({WebUiLease? lease}) async =>
      _list(_object(await request('GET', 'api/models', lease: lease))['data']);
  Future<List<Map<String, dynamic>>> chats({
    required WebUiLease lease,
    int page = 1,
    bool archived = false,
    String? query,
  }) async => _list(
    await request(
      'GET',
      query != null
          ? 'api/v1/chats/search'
          : archived
          ? 'api/v1/chats/archived'
          : 'api/v1/chats/',
      query: {
        'page': '$page',
        'include_pinned': 'true',
        'include_folders': 'true',
        if (query != null) 'text': query,
      },
      lease: lease,
    ),
  );
  Future<Map<String, dynamic>> chat(String id, WebUiLease lease) async =>
      _object(
        await request(
          'GET',
          'api/v1/chats/${Uri.encodeComponent(id)}',
          lease: lease,
        ),
      );
  Future<List<String>> tasks(String id, WebUiLease lease) async =>
      (_object(
                    await request(
                      'GET',
                      'api/tasks/chat/${Uri.encodeComponent(id)}',
                      lease: lease,
                    ),
                  )['task_ids']
                  as List? ??
              const [])
          .cast<String>();
  Future<void> stop(String id, WebUiLease lease) async {
    await request(
      'POST',
      'api/tasks/chat/${Uri.encodeComponent(id)}/stop',
      lease: lease,
    );
  }

  Future<Map<String, dynamic>> createChat(
    Map<String, dynamic> initial,
    WebUiLease lease, {
    String? folderId,
  }) async => _object(
    await request(
      'POST',
      'api/v1/chats/new',
      body: {'chat': initial, if (folderId != null) 'folder_id': folderId},
      lease: lease,
    ),
  );
  Future<Map<String, dynamic>> rename(
    String id,
    String title,
    WebUiLease lease,
  ) async => _object(
    await request(
      'POST',
      'api/v1/chats/${Uri.encodeComponent(id)}',
      body: {
        'chat': {'title': title},
      },
      lease: lease,
    ),
  );
  Future<void> deleteChat(String id, WebUiLease lease) async {
    await request(
      'DELETE',
      'api/v1/chats/${Uri.encodeComponent(id)}',
      lease: lease,
    );
  }

  Future<Map<String, dynamic>> toggle(
    String id,
    String action,
    WebUiLease lease,
  ) async {
    if (!{'pin', 'archive'}.contains(action)) throw ArgumentError.value(action);
    return _object(
      await request(
        'POST',
        'api/v1/chats/${Uri.encodeComponent(id)}/$action',
        lease: lease,
      ),
    );
  }

  Future<dynamic> request(
    String method,
    String relative, {
    Object? body,
    Map<String, String>? query,
    WebUiLease? lease,
  }) async {
    lease?.check();
    final request = http.Request(method, endpoint(relative, query))
      ..followRedirects = false
      ..headers.addAll(options.headers);
    if (body != null) request.body = jsonEncode(body);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    lease?.check();
    final bytes = <int>[];
    await for (final part in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      lease?.check();
      if (bytes.length + part.length > 16 * 1024 * 1024) {
        throw const WebUiException('The server response exceeds 16 MB.');
      }
      bytes.addAll(part);
    }
    lease?.check();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401) lease?.session.lock();
      throw WebUiException(switch (response.statusCode) {
        401 => 'Access could not be verified. Sign in again; local drafts are retained.',
        403 => 'This account cannot access this server feature.',
        404 => 'This server resource is unavailable.',
        >= 300 && < 400 =>
          'The server redirected this request. Use its final server address.',
        _ => 'The server returned HTTP ${response.statusCode}.',
      }, status: response.statusCode);
    }
    if (bytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(bytes));
    } on Object {
      throw const WebUiException('The server returned an unreadable response.');
    }
  }

  /// Streams or task acknowledgments stay typed; an empty accepted body does
  /// not trigger a second dispatch. The run owner fetches authoritative output.
  Future<http.StreamedResponse> dispatch(
    Map<String, dynamic> body,
    WebUiLease lease,
  ) async {
    lease.check();
    final request = http.Request('POST', endpoint('api/chat/completions'))
      ..followRedirects = false
      ..headers.addAll(options.headers)
      ..body = jsonEncode(body);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    lease.check();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode == 401) lease.session.lock();
      throw WebUiException(
        'The server returned HTTP ${response.statusCode}. Reconcile this request before retrying.',
        status: response.statusCode,
      );
    }
    return response;
  }

  Future<Map<String, dynamic>> upload(
    String name,
    List<int> bytes,
    String mimeType,
    WebUiLease lease,
  ) async {
    lease.check();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const WebUiException('Choose a nonempty file of up to 8 MB.');
    }
    final request =
        http.MultipartRequest(
            'POST',
            endpoint('api/v1/files/', {
              'process': 'true',
              'process_in_background': 'true',
            }),
          )
          ..followRedirects = false
          ..headers.addAll({...options.headers}..remove('content-type'))
          ..files.add(
            http.MultipartFile.fromBytes(
              'file',
              bytes,
              filename: name,
              contentType: MediaType.parse(mimeType),
            ),
          );
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 60));
    lease.check();
    final body = await _boundedBytes(response, lease);
    if (response.statusCode == 401) lease.session.lock();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WebUiException(
        'Upload failed (HTTP ${response.statusCode}). Your draft is retained.',
        status: response.statusCode,
      );
    }
    return _object(jsonDecode(utf8.decode(body)));
  }

  /// Credentials can accompany only the selected server's file route. No
  /// redirects, external Markdown images, or arbitrary authenticated URLs.
  Uri fileUri(String reference) {
    final candidate = Uri.parse(reference);
    final Uri uri;
    if (candidate.hasScheme) {
      uri = candidate.normalizePath();
    } else if (root.path.isNotEmpty &&
        candidate.path.startsWith('${root.path}/api/')) {
      uri = root.resolveUri(candidate).normalizePath();
    } else {
      uri = endpoint(reference.replaceFirst(RegExp(r'^/+'), ''))
          .normalizePath();
    }
    final prefix = '${root.path}/api/v1/files/';
    final suffix = uri.path.startsWith(prefix)
        ? uri.path.substring(prefix.length).split('/')
        : const <String>[];
    if (uri.origin != root.origin ||
        uri.userInfo.isNotEmpty ||
        !uri.path.startsWith(prefix) ||
        suffix.length < 2 ||
        suffix.length > 3 ||
        suffix[0].isEmpty ||
        suffix[1] != 'content' ||
        uri.pathSegments.any(
          (segment) =>
              segment == '..' || segment == '.' || segment.contains('/'),
        ) ||
        candidate.hasQuery ||
        candidate.hasFragment ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const WebUiException(
        'This file is outside the connected server’s file service.',
      );
    }
    return uri;
  }

  Future<Uint8List> fileBytes(String reference, WebUiLease lease) async {
    lease.check();
    final request = http.Request('GET', fileUri(reference))
      ..followRedirects = false
      ..headers.addAll(options.headers);
    final response = await _client
        .send(request)
        .timeout(const Duration(seconds: 30));
    lease.check();
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      if (response.statusCode == 401) lease.session.lock();
      throw WebUiException(
        'This source is unavailable (HTTP ${response.statusCode}).',
        status: response.statusCode,
      );
    }
    return _boundedBytes(response, lease, maximum: 8 * 1024 * 1024);
  }

  Future<Uint8List> _boundedBytes(
    http.StreamedResponse response,
    WebUiLease lease, {
    int maximum = 16 * 1024 * 1024,
  }) async {
    final bytes = BytesBuilder(copy: false);
    await for (final part in response.stream.timeout(
      const Duration(seconds: 30),
    )) {
      lease.check();
      if (bytes.length + part.length > maximum) {
        throw WebUiException(
          'The server file exceeds ${maximum ~/ (1024 * 1024)} MB.',
        );
      }
      bytes.add(part);
    }
    lease.check();
    return bytes.takeBytes();
  }

  void close() => _client.close();
  static Map<String, dynamic> _object(Object? value) => value is Map
      ? Map<String, dynamic>.from(value)
      : throw const WebUiException('Expected a server object.');
  static List<Map<String, dynamic>> _list(Object? value) => value is List
      ? value.map(_object).toList()
      : throw const WebUiException('Expected a server list.');
}
