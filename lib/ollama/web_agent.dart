import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ollama_client.dart';

final class WebAgent {
  static const int maxToolCallsPerTurn = 8;
  static const int maxToolCallsPerRun = 24;

  factory WebAgent({
    required OllamaClient ollama,
    required HttpClientFactory webClientFactory,
    required String apiKey,
    int maxTurns = 8,
    int maxSearchResults = 5,
    int maxFetchLinks = 20,
    int maxToolResultCharacters = 12000,
    int maxFetchUrlCharacters = 4096,
    int maxResponseBodyBytes = 2 * 1024 * 1024,
    int maxErrorBodyBytes = 16 * 1024,
    Duration requestTimeout = const Duration(seconds: 20),
  }) => WebAgent.withChatStarter(
    startChat: ollama.startChat,
    webClientFactory: webClientFactory,
    apiKey: apiKey,
    maxTurns: maxTurns,
    maxSearchResults: maxSearchResults,
    maxFetchLinks: maxFetchLinks,
    maxToolResultCharacters: maxToolResultCharacters,
    maxFetchUrlCharacters: maxFetchUrlCharacters,
    maxResponseBodyBytes: maxResponseBodyBytes,
    maxErrorBodyBytes: maxErrorBodyBytes,
    requestTimeout: requestTimeout,
  );

  WebAgent.withChatStarter({
    required OllamaChatStarter startChat,
    required HttpClientFactory webClientFactory,
    required String apiKey,
    this.maxTurns = 8,
    this.maxSearchResults = 5,
    this.maxFetchLinks = 20,
    this.maxToolResultCharacters = 12000,
    this.maxFetchUrlCharacters = 4096,
    this.maxResponseBodyBytes = 2 * 1024 * 1024,
    this.maxErrorBodyBytes = 16 * 1024,
    this.requestTimeout = const Duration(seconds: 20),
  }) : _startChat = startChat,
       _webClientFactory = webClientFactory,
       _apiKey = apiKey.trim() {
    if (_apiKey.isEmpty) throw ArgumentError('Ollama API key is required');
    if (maxTurns < 1 || maxTurns > 8) {
      throw RangeError.range(maxTurns, 1, 8, 'maxTurns');
    }
    if (maxSearchResults < 1 || maxSearchResults > 10) {
      throw RangeError.range(maxSearchResults, 1, 10, 'maxSearchResults');
    }
    if (maxFetchLinks < 0 ||
        maxToolResultCharacters < 256 ||
        maxFetchUrlCharacters < 1 ||
        maxResponseBodyBytes < 1 ||
        maxErrorBodyBytes < 1) {
      throw ArgumentError('Invalid web result bounds');
    }
  }

  static final Uri _searchEndpoint = Uri.parse(
    'https://ollama.com/api/web_search',
  );
  static final Uri _fetchEndpoint = Uri.parse(
    'https://ollama.com/api/web_fetch',
  );

  static const tools = <OllamaToolDefinition>[
    OllamaToolDefinition(
      name: 'web_search',
      description: 'Search the web for current information.',
      parameters: {
        'type': 'object',
        'required': ['query'],
        'additionalProperties': false,
        'properties': {
          'query': {'type': 'string', 'description': 'The search query.'},
          'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 10},
        },
      },
    ),
    OllamaToolDefinition(
      name: 'web_fetch',
      description: 'Fetch the readable content of one web page.',
      parameters: {
        'type': 'object',
        'required': ['url'],
        'additionalProperties': false,
        'properties': {
          'url': {
            'type': 'string',
            'description': 'An HTTP or HTTPS page URL.',
          },
        },
      },
    ),
  ];

  final OllamaChatStarter _startChat;
  final HttpClientFactory _webClientFactory;
  final String _apiKey;
  final int maxTurns;
  final int maxSearchResults;
  final int maxFetchLinks;
  final int maxToolResultCharacters;
  final int maxFetchUrlCharacters;
  final int maxResponseBodyBytes;
  final int maxErrorBodyBytes;
  final Duration requestTimeout;

  /// Creates a cold, request-scoped agent run.
  ///
  /// Each run owns and can cancel its active model stream and each web-tool
  /// HTTP client. [webClientFactory] must return a fresh client for every tool
  /// request; every returned client is closed by the run that claimed it.
  WebAgentRun run({
    required String model,
    required List<OllamaChatMessage> messages,
    bool? think,
    Map<String, Object> options = const {},
  }) {
    if (model.trim().isEmpty) {
      throw ArgumentError.value(model, 'model', 'must not be empty');
    }
    final cancellation = _WebAgentCancellation();
    return WebAgentRun._(
      _run(
        model: model.trim(),
        messages: List.unmodifiable(messages),
        think: think,
        options: Map<String, Object>.unmodifiable(options),
        cancellation: cancellation,
      ),
      cancellation,
    );
  }

  Stream<WebAgentEvent> _run({
    required String model,
    required List<OllamaChatMessage> messages,
    required bool? think,
    required Map<String, Object> options,
    required _WebAgentCancellation cancellation,
  }) async* {
    final transcript = List<OllamaChatMessage>.of(messages);
    var totalToolCalls = 0;

    try {
      for (var turn = 1; turn <= maxTurns; turn++) {
        cancellation.throwIfCancelled();
        yield WebAgentTurnStarted(turn);

        final content = StringBuffer();
        final thinking = StringBuffer();
        final toolCalls = _ToolCallAccumulator(maxCalls: maxToolCallsPerTurn);
        final chat = _startChat(
          OllamaChatRequest(
            model: model,
            messages: transcript,
            tools: tools,
            think: think,
            options: options,
          ),
        );
        cancellation.attachChat(chat);

        var sawDone = false;
        String? terminalDoneReason;
        try {
          await for (final chunk in chat.stream) {
            cancellation.throwIfCancelled();
            if (chunk.toolProgress case final progress?) {
              yield WebAgentProviderToolProgress(
                turn: turn,
                progress: progress,
              );
            }
            if (chunk.message.thinking.isNotEmpty) {
              thinking.write(chunk.message.thinking);
              yield WebAgentThinkingDelta(
                turn: turn,
                delta: chunk.message.thinking,
              );
            }
            if (chunk.message.content.isNotEmpty) {
              content.write(chunk.message.content);
              yield WebAgentContentDelta(
                turn: turn,
                delta: chunk.message.content,
              );
            }
            toolCalls.addAll(chunk.message.toolCalls);
            if (chunk.done) {
              sawDone = true;
              terminalDoneReason = chunk.doneReason;
            }
          }
        } finally {
          cancellation.detachChat(chat);
        }
        cancellation.throwIfCancelled();
        if (!sawDone) {
          throw const WebAgentExecutionException(
            'Model stream ended before a terminal completion response',
          );
        }
        final completedToolCalls = toolCalls.calls;
        final completedForTools =
            terminalDoneReason == 'tool_calls' && completedToolCalls.isNotEmpty;
        if (terminalDoneReason != null &&
            terminalDoneReason != 'stop' &&
            !completedForTools) {
          throw WebAgentExecutionException(
            'The model stopped the Web Agent turn with reason: '
            '$terminalDoneReason',
          );
        }
        if (totalToolCalls + completedToolCalls.length > maxToolCallsPerRun) {
          throw WebAgentLimitException.toolCalls(
            limit: maxToolCallsPerRun,
            scope: 'one Web Agent run',
          );
        }
        totalToolCalls += completedToolCalls.length;

        final assistant = OllamaChatMessage(
          role: OllamaRole.assistant,
          content: content.toString(),
          thinking: thinking.toString(),
          toolCalls: completedToolCalls,
        );
        transcript.add(assistant);

        if (completedToolCalls.isEmpty) {
          yield WebAgentCompleted(
            turns: turn,
            answer: assistant.content,
            thinking: assistant.thinking,
            messages: List.unmodifiable(transcript),
          );
          return;
        }

        if (turn == maxTurns) {
          throw WebAgentLimitException(maxTurns);
        }

        for (final call in completedToolCalls) {
          yield WebAgentToolActivity(
            turn: turn,
            call: call,
            state: WebToolActivityState.running,
          );

          try {
            final result = await _execute(call, cancellation);
            final content = _boundedJson(result.toJson());
            transcript.add(
              OllamaChatMessage(
                role: OllamaRole.tool,
                content: content,
                toolName: call.name,
                toolCallId: call.id,
              ),
            );
            yield WebAgentToolActivity(
              turn: turn,
              call: call,
              state: WebToolActivityState.completed,
              result: result,
            );
          } on WebAgentCancelledException {
            rethrow;
          } on WebAgentExecutionException {
            rethrow;
          } on WebAgentException catch (error) {
            transcript.add(
              OllamaChatMessage(
                role: OllamaRole.tool,
                content: _boundedJson({'error': error.message}),
                toolName: call.name,
                toolCallId: call.id,
              ),
            );
            yield WebAgentToolActivity(
              turn: turn,
              call: call,
              state: WebToolActivityState.failed,
              error: error,
            );
          }
        }
      }
    } on WebAgentCancelledException {
      return;
    } on WebAgentException catch (error) {
      yield WebAgentFailed(error);
    } on OllamaCancelledException catch (error) {
      if (cancellation.isCancelled) return;
      yield WebAgentFailed(
        WebAgentExecutionException('Model request failed', cause: error),
      );
    } on OllamaException catch (error) {
      yield WebAgentFailed(
        WebAgentExecutionException('Model request failed', cause: error),
      );
    } catch (error) {
      yield WebAgentFailed(
        WebAgentExecutionException('Web agent failed', cause: error),
      );
    } finally {
      await cancellation.closeActive();
    }
  }

  Future<WebToolResult> _execute(
    OllamaToolCall call,
    _WebAgentCancellation cancellation,
  ) {
    cancellation.throwIfCancelled();
    return switch (call.name) {
      'web_search' => _search(call.arguments, cancellation),
      'web_fetch' => _fetch(call.arguments, cancellation),
      _ => throw WebToolValidationException(call.name, 'Unsupported tool name'),
    };
  }

  Future<WebSearchResult> _search(
    Map<String, dynamic> arguments,
    _WebAgentCancellation cancellation,
  ) async {
    _validateKeys('web_search', arguments, const {'query', 'max_results'});
    final query = arguments['query'];
    if (query is! String) {
      throw const WebToolValidationException(
        'web_search',
        'query must be a non-empty string of at most 500 characters',
      );
    }
    final normalizedQuery = query.trim();
    if (normalizedQuery.isEmpty ||
        normalizedQuery.length > 500 ||
        RegExp(r'[\u0000-\u001f\u007f]').hasMatch(normalizedQuery)) {
      throw const WebToolValidationException(
        'web_search',
        'query must be a non-empty string of at most 500 characters without control characters',
      );
    }

    final requested = arguments['max_results'] ?? maxSearchResults;
    if (requested is! int || requested < 1 || requested > 10) {
      throw const WebToolValidationException(
        'web_search',
        'max_results must be an integer from 1 through 10',
      );
    }
    final limit = math.min(requested, maxSearchResults);
    final json = await _post(_searchEndpoint, {
      'query': normalizedQuery,
      'max_results': limit,
    }, cancellation);
    final rawResults = json['results'];
    if (rawResults is! List) {
      throw const WebToolProtocolException(
        'web_search response is missing results',
      );
    }

    final results = rawResults
        .take(limit)
        .map((value) {
          final item = _object(value, 'web_search result');
          return WebSearchItem(
            title: _boundedString(item['title'], 500),
            url: _boundedString(item['url'], 2048),
            content: _boundedString(item['content'], 4000),
          );
        })
        .toList(growable: false);
    return WebSearchResult(results);
  }

  Future<WebFetchResult> _fetch(
    Map<String, dynamic> arguments,
    _WebAgentCancellation cancellation,
  ) async {
    _validateKeys('web_fetch', arguments, const {'url'});
    final rawUrl = arguments['url'];
    if (rawUrl is! String) {
      throw const WebToolValidationException(
        'web_fetch',
        'url must be a string',
      );
    }
    final normalizedUrl = rawUrl.trim();
    if (normalizedUrl.isEmpty ||
        rawUrl.length > maxFetchUrlCharacters ||
        normalizedUrl.length > maxFetchUrlCharacters) {
      throw WebToolValidationException(
        'web_fetch',
        'url must contain at most $maxFetchUrlCharacters characters',
      );
    }
    if (rawUrl != normalizedUrl ||
        RegExp(r'[\u0000-\u0020\u007f]').hasMatch(normalizedUrl)) {
      throw const WebToolValidationException(
        'web_fetch',
        'url must not contain whitespace or control characters',
      );
    }
    final url = Uri.tryParse(normalizedUrl);
    if (url == null ||
        !url.hasAuthority ||
        (url.scheme != 'http' && url.scheme != 'https') ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.authority.contains('@')) {
      throw const WebToolValidationException(
        'web_fetch',
        'url must be an absolute HTTP(S) URL without credentials',
      );
    }
    if (!_isPublicFetchHost(url.host)) {
      throw const WebToolValidationException(
        'web_fetch',
        'url host must be a public DNS name or public IP address',
      );
    }

    final json = await _post(_fetchEndpoint, {
      'url': url.toString(),
    }, cancellation);
    final rawLinks = json['links'];
    if (rawLinks != null && rawLinks is! List) {
      throw const WebToolProtocolException('web_fetch links must be an array');
    }
    final links = (rawLinks as List? ?? const [])
        .take(maxFetchLinks)
        .map((value) => _boundedString(value, 2048))
        .toList(growable: false);
    return WebFetchResult(
      title: _boundedString(json['title'], 500),
      content: _boundedString(json['content'], maxToolResultCharacters),
      links: links,
    );
  }

  Future<Map<String, dynamic>> _post(
    Uri endpoint,
    Map<String, dynamic> body,
    _WebAgentCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    http.Client? requestClient;
    try {
      requestClient = _webClientFactory();
      cancellation.attachWebClient(requestClient);
      final request = http.Request('POST', endpoint)
        ..headers.addAll({
          'Authorization': 'Bearer $_apiKey',
          'Content-Type': 'application/json',
        })
        ..body = jsonEncode(body);
      final response = await requestClient
          .send(request)
          .timeout(requestTimeout);
      cancellation.throwIfCancelled();
      final successful =
          response.statusCode >= 200 && response.statusCode < 300;
      final responseBody = await _readBoundedWebBody(
        response.stream,
        maxBytes: successful ? maxResponseBodyBytes : maxErrorBodyBytes,
      ).timeout(requestTimeout);
      cancellation.throwIfCancelled();
      if (!successful) {
        final detail = _sanitizeErrorDetail(
          responseBody.text(allowMalformed: true),
          truncated: responseBody.truncated,
        );
        throw WebToolHttpException(
          endpoint: endpoint,
          statusCode: response.statusCode,
          body: detail,
        );
      }
      if (responseBody.truncated) {
        throw WebToolResponseTooLargeException(
          endpoint: endpoint,
          maxBytes: maxResponseBodyBytes,
        );
      }
      return _object(jsonDecode(responseBody.text()), 'web tool response');
    } on WebAgentCancelledException {
      rethrow;
    } on WebAgentException {
      rethrow;
    } on TimeoutException catch (error) {
      if (cancellation.isCancelled) {
        throw const WebAgentCancelledException();
      }
      throw WebToolTransportException(
        'Web tool request timed out',
        cause: error,
      );
    } on http.ClientException catch (error) {
      if (cancellation.isCancelled) {
        throw const WebAgentCancelledException();
      }
      throw WebToolTransportException(
        'Web tool connection failed',
        cause: error,
      );
    } on FormatException catch (error) {
      throw WebToolProtocolException('Invalid web tool JSON', cause: error);
    } finally {
      if (requestClient != null) {
        cancellation.detachAndCloseWebClient(requestClient);
      }
    }
  }

  String _sanitizeErrorDetail(String raw, {required bool truncated}) {
    var detail = raw;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final candidate = decoded['error'] ?? decoded['message'];
        if (candidate is String) detail = candidate;
      }
    } on FormatException {
      // Plain-text error bodies are valid diagnostic detail.
    }
    detail = detail.replaceAll(_apiKey, '[redacted]');
    detail = detail.replaceAll(
      RegExp(r'bearer\s+\S+', caseSensitive: false),
      'Bearer [redacted]',
    );
    detail = detail
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (detail.length > 1000) {
      detail = detail.substring(0, 1000);
      truncated = true;
    }
    if (truncated) {
      detail = detail.isEmpty ? '[truncated]' : '$detail [truncated]';
    }
    return detail;
  }

  static bool _isPublicFetchHost(String rawHost) {
    var host = rawHost.toLowerCase();
    while (host.endsWith('.')) {
      host = host.substring(0, host.length - 1);
    }
    if (host.isEmpty || host.length > 253) return false;

    final address = InternetAddress.tryParse(host);
    if (address != null) {
      final bytes = address.rawAddress;
      if (bytes.length == 4) return _isPublicIpv4(bytes);
      if (bytes.length != 16) return false;

      final ipv4Mapped =
          bytes.take(10).every((byte) => byte == 0) &&
          bytes[10] == 0xff &&
          bytes[11] == 0xff;
      if (ipv4Mapped) return _isPublicIpv4(bytes.sublist(12));

      // Public IPv6 unicast is allocated from 2000::/3. Exclude the
      // documentation prefix even though it lies inside that range.
      final globalUnicast = (bytes[0] & 0xe0) == 0x20;
      final documentation =
          bytes[0] == 0x20 &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x0d &&
          bytes[3] == 0xb8;
      return globalUnicast && !documentation;
    }

    // Reject alternate numeric IP spellings before treating the host as DNS.
    if (RegExp(r'^[0-9.]+$').hasMatch(host) ||
        RegExp(r'^0x[0-9a-f]+(?:\.(?:0x[0-9a-f]+|[0-9]+))*$').hasMatch(host)) {
      return false;
    }

    final labels = host.split('.');
    if (labels.length < 2) return false;
    const blockedSuffixes = {
      'localhost',
      'local',
      'internal',
      'lan',
      'home',
      'home.arpa',
      'invalid',
      'test',
      'example',
      'onion',
    };
    if (blockedSuffixes.any(
      (suffix) => host == suffix || host.endsWith('.$suffix'),
    )) {
      return false;
    }
    final validLabel = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    if (labels.any((label) => !validLabel.hasMatch(label))) return false;
    return RegExp(r'[a-z]').hasMatch(labels.last);
  }

  static bool _isPublicIpv4(List<int> bytes) {
    final first = bytes[0];
    final second = bytes[1];
    final third = bytes[2];
    final nonPublic =
        first == 0 ||
        first == 10 ||
        first == 127 ||
        (first == 100 && second >= 64 && second <= 127) ||
        (first == 169 && second == 254) ||
        (first == 172 && second >= 16 && second <= 31) ||
        (first == 192 && second == 0 && third == 0) ||
        (first == 192 && second == 0 && third == 2) ||
        (first == 192 && second == 168) ||
        (first == 198 && (second == 18 || second == 19)) ||
        (first == 198 && second == 51 && third == 100) ||
        (first == 203 && second == 0 && third == 113) ||
        first >= 224;
    return !nonPublic;
  }

  void _validateKeys(
    String tool,
    Map<String, dynamic> arguments,
    Set<String> allowed,
  ) {
    final unexpected = arguments.keys.where((key) => !allowed.contains(key));
    if (unexpected.isNotEmpty) {
      throw WebToolValidationException(
        tool,
        'Unexpected argument: ${unexpected.first}',
      );
    }
  }

  String _boundedJson(Map<String, dynamic> value) {
    final encoded = jsonEncode(value);
    if (encoded.length <= maxToolResultCharacters) return encoded;

    var excerptLength = math.max(1, maxToolResultCharacters ~/ 4);
    while (true) {
      final bounded = jsonEncode({
        'truncated': true,
        'excerpt': encoded.substring(0, excerptLength),
      });
      if (bounded.length <= maxToolResultCharacters || excerptLength == 1) {
        return bounded;
      }
      excerptLength = math.max(1, excerptLength ~/ 2);
    }
  }

  static Map<String, dynamic> _object(Object? value, String label) {
    if (value is! Map) {
      throw WebToolProtocolException('$label must be an object');
    }
    return Map<String, dynamic>.from(value);
  }

  static String _boundedString(Object? value, int limit) {
    if (value is! String) {
      throw const WebToolProtocolException('Expected a string');
    }
    return value.length <= limit ? value : value.substring(0, limit);
  }
}

final class WebAgentRun {
  WebAgentRun._(this.stream, this._cancellation);

  final Stream<WebAgentEvent> stream;
  final _WebAgentCancellation _cancellation;

  bool get isCancelled => _cancellation.isCancelled;

  Future<void> cancel() => _cancellation.cancel();
}

final class _WebAgentCancellation {
  static final Expando<bool> _claimedWebClients = Expando<bool>();

  bool isCancelled = false;
  OllamaChatStream? _activeChat;
  http.Client? _activeWebClient;

  void throwIfCancelled() {
    if (isCancelled) throw const WebAgentCancelledException();
  }

  void attachChat(OllamaChatStream chat) {
    if (isCancelled) {
      unawaited(chat.cancel());
      throw const WebAgentCancelledException();
    }
    if (_activeChat != null) {
      unawaited(chat.cancel());
      throw const WebAgentExecutionException(
        'A Web Agent run cannot own two active model streams',
      );
    }
    _activeChat = chat;
  }

  void detachChat(OllamaChatStream chat) {
    if (identical(_activeChat, chat)) _activeChat = null;
  }

  void attachWebClient(http.Client client) {
    if (isCancelled) {
      client.close();
      throw const WebAgentCancelledException();
    }
    if (_activeWebClient != null) {
      client.close();
      throw const WebAgentExecutionException(
        'A Web Agent run cannot own two active web requests',
      );
    }
    if (_claimedWebClients[client] == true) {
      client.close();
      throw const WebAgentExecutionException(
        'webClientFactory must return a fresh client for every request',
      );
    }
    _claimedWebClients[client] = true;
    _activeWebClient = client;
  }

  void detachAndCloseWebClient(http.Client client) {
    if (identical(_activeWebClient, client)) _activeWebClient = null;
    client.close();
  }

  Future<void> cancel() async {
    if (isCancelled) return;
    isCancelled = true;
    final webClient = _activeWebClient;
    _activeWebClient = null;
    webClient?.close();
    final chat = _activeChat;
    _activeChat = null;
    await chat?.cancel();
  }

  Future<void> closeActive() async {
    final webClient = _activeWebClient;
    _activeWebClient = null;
    webClient?.close();
    final chat = _activeChat;
    _activeChat = null;
    await chat?.cancel();
  }
}

final class _ToolCallAccumulator {
  _ToolCallAccumulator({required this.maxCalls});

  final int maxCalls;
  final List<OllamaToolCall> _calls = <OllamaToolCall>[];
  final Map<int, int> _positionByIndex = <int, int>{};

  List<OllamaToolCall> get calls => List<OllamaToolCall>.unmodifiable(_calls);

  void addAll(List<OllamaToolCall> fragments) {
    for (final fragment in fragments) {
      final index = fragment.index;
      if (index != null && index < 0) {
        throw const WebAgentExecutionException(
          'The model returned a negative tool-call index',
        );
      }

      final existingPosition = index == null ? null : _positionByIndex[index];
      if (existingPosition != null) {
        _calls[existingPosition] = _merge(_calls[existingPosition], fragment);
        continue;
      }

      if (_calls.length >= maxCalls) {
        throw WebAgentLimitException.toolCalls(
          limit: maxCalls,
          scope: 'one model turn',
        );
      }
      if (index != null) _positionByIndex[index] = _calls.length;
      _calls.add(fragment);
    }
  }

  static OllamaToolCall _merge(
    OllamaToolCall existing,
    OllamaToolCall fragment,
  ) {
    if (existing.id != null &&
        fragment.id != null &&
        existing.id != fragment.id) {
      throw WebAgentExecutionException(
        'The model reused tool-call index ${existing.index} with two ids',
      );
    }
    if (existing.name.isNotEmpty &&
        fragment.name.isNotEmpty &&
        existing.name != fragment.name) {
      throw WebAgentExecutionException(
        'The model reused tool-call index ${existing.index} for two tools',
      );
    }
    return OllamaToolCall(
      index: existing.index,
      id: fragment.id ?? existing.id,
      name: fragment.name.isNotEmpty ? fragment.name : existing.name,
      description: fragment.description ?? existing.description,
      arguments: <String, dynamic>{
        ...existing.arguments,
        ...fragment.arguments,
      },
    );
  }
}

Future<_WebBoundedBody> _readBoundedWebBody(
  Stream<List<int>> stream, {
  required int maxBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    final remaining = maxBytes - bytes.length;
    if (chunk.length > remaining) {
      if (remaining > 0) bytes.add(chunk.sublist(0, remaining));
      return _WebBoundedBody(bytes.takeBytes(), truncated: true);
    }
    bytes.add(chunk);
  }
  return _WebBoundedBody(bytes.takeBytes(), truncated: false);
}

final class _WebBoundedBody {
  const _WebBoundedBody(this.bytes, {required this.truncated});

  final Uint8List bytes;
  final bool truncated;

  String text({bool allowMalformed = false}) =>
      utf8.decode(bytes, allowMalformed: allowMalformed);
}

sealed class WebAgentEvent {
  const WebAgentEvent();
}

final class WebAgentTurnStarted extends WebAgentEvent {
  const WebAgentTurnStarted(this.turn);

  final int turn;
}

final class WebAgentThinkingDelta extends WebAgentEvent {
  const WebAgentThinkingDelta({required this.turn, required this.delta});

  final int turn;
  final String delta;
}

final class WebAgentContentDelta extends WebAgentEvent {
  const WebAgentContentDelta({required this.turn, required this.delta});

  final int turn;
  final String delta;
}

final class WebAgentProviderToolProgress extends WebAgentEvent {
  const WebAgentProviderToolProgress({
    required this.turn,
    required this.progress,
  });

  final int turn;
  final OllamaToolProgress progress;
}

enum WebToolActivityState { running, completed, failed }

final class WebAgentToolActivity extends WebAgentEvent {
  const WebAgentToolActivity({
    required this.turn,
    required this.call,
    required this.state,
    this.result,
    this.error,
  });

  final int turn;
  final OllamaToolCall call;
  final WebToolActivityState state;
  final WebToolResult? result;
  final WebAgentException? error;
}

final class WebAgentCompleted extends WebAgentEvent {
  const WebAgentCompleted({
    required this.turns,
    required this.answer,
    required this.thinking,
    required this.messages,
  });

  final int turns;
  final String answer;
  final String thinking;
  final List<OllamaChatMessage> messages;
}

final class WebAgentFailed extends WebAgentEvent {
  const WebAgentFailed(this.error);

  final WebAgentException error;
}

sealed class WebToolResult {
  const WebToolResult();

  Map<String, dynamic> toJson();
}

final class WebSearchResult extends WebToolResult {
  const WebSearchResult(this.results);

  final List<WebSearchItem> results;

  @override
  Map<String, dynamic> toJson() => {
    'results': results.map((result) => result.toJson()).toList(),
  };
}

final class WebSearchItem {
  const WebSearchItem({
    required this.title,
    required this.url,
    required this.content,
  });

  final String title;
  final String url;
  final String content;

  Map<String, dynamic> toJson() => {
    'title': title,
    'url': url,
    'content': content,
  };
}

final class WebFetchResult extends WebToolResult {
  const WebFetchResult({
    required this.title,
    required this.content,
    required this.links,
  });

  final String title;
  final String content;
  final List<String> links;

  @override
  Map<String, dynamic> toJson() => {
    'title': title,
    'content': content,
    'links': links,
  };
}

sealed class WebAgentException implements Exception {
  const WebAgentException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

final class WebAgentLimitException extends WebAgentException {
  WebAgentLimitException(int turns)
    : super('Web agent stopped after $turns model turns');

  WebAgentLimitException.toolCalls({required int limit, required String scope})
    : super('Web agent stopped after reaching $limit tool calls in $scope');
}

final class WebAgentExecutionException extends WebAgentException {
  const WebAgentExecutionException(super.message, {super.cause});
}

final class WebAgentCancelledException extends WebAgentException {
  const WebAgentCancelledException() : super('Web agent cancelled');
}

final class WebToolValidationException extends WebAgentException {
  const WebToolValidationException(this.tool, String message) : super(message);

  final String tool;
}

final class WebToolHttpException extends WebAgentException {
  WebToolHttpException({
    required this.endpoint,
    required this.statusCode,
    required this.body,
  }) : super(
         body.isEmpty
             ? 'Web tool returned HTTP $statusCode'
             : 'Web tool returned HTTP $statusCode: $body',
       );

  final Uri endpoint;
  final int statusCode;
  final String body;
}

final class WebToolTransportException extends WebAgentException {
  const WebToolTransportException(super.message, {super.cause});
}

final class WebToolProtocolException extends WebAgentException {
  const WebToolProtocolException(super.message, {super.cause});
}

final class WebToolResponseTooLargeException extends WebAgentException {
  WebToolResponseTooLargeException({
    required this.endpoint,
    required this.maxBytes,
  }) : super('Web tool response exceeds the $maxBytes byte limit');

  final Uri endpoint;
  final int maxBytes;
}
