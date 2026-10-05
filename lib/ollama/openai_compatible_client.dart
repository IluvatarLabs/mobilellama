import 'sse.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ollama_client.dart';
import 'connection_options.dart';
import 'responses_codec.dart';
import '../data/settings_store.dart' show CompatibleApi;

/// OpenAI-compatible transport rooted at the user's exact API deployment path.
///
/// The injected unary client remains caller-owned. Every streaming client is
/// request-scoped, must be fresh, and is closed by its [OllamaChatStream].
final class OpenAiCompatibleClient {
  static final Expando<bool> _claimedStreamingClients = Expando<bool>();

  OpenAiCompatibleClient({
    required String baseUrl,
    required String apiKey,
    required http.Client client,
    ConnectionOptions? connectionOptions,
    HttpClientFactory? streamingClientFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.streamIdleTimeout = const Duration(minutes: 2),
    this.maxResponseBodyBytes = 4 * 1024 * 1024,
    this.maxErrorBodyBytes = 16 * 1024,
    this.maxSseLineBytes = 1024 * 1024,
    this.maxSseEventBytes = 1024 * 1024,
  }) : baseUri = normalizeBaseUrl(baseUrl),
       connectionOptions =
           connectionOptions ?? ConnectionOptions(apiKey: apiKey.trim()),
       _client = client,
       _streamingClientFactory = streamingClientFactory ?? http.Client.new {
    if (maxResponseBodyBytes < 1 ||
        maxErrorBodyBytes < 1 ||
        maxSseLineBytes < 1 ||
        maxSseEventBytes < 1) {
      throw ArgumentError('OpenAI-compatible response bounds must be positive');
    }
  }

  final Uri baseUri;
  final ConnectionOptions connectionOptions;

  OpenAiCompatibleClient withConnectionOptions(ConnectionOptions options) =>
      OpenAiCompatibleClient(
        baseUrl: baseUri.toString(),
        apiKey: options.apiKey,
        client: _client,
        connectionOptions: options,
        streamingClientFactory: _streamingClientFactory,
        requestTimeout: requestTimeout,
        streamIdleTimeout: streamIdleTimeout,
        maxResponseBodyBytes: maxResponseBodyBytes,
        maxErrorBodyBytes: maxErrorBodyBytes,
        maxSseLineBytes: maxSseLineBytes,
        maxSseEventBytes: maxSseEventBytes,
      );
  final http.Client _client;
  final HttpClientFactory _streamingClientFactory;
  final Duration requestTimeout;
  final Duration streamIdleTimeout;
  final int maxResponseBodyBytes;
  final int maxErrorBodyBytes;
  final int maxSseLineBytes;
  final int maxSseEventBytes;
  List<OpenAiCompatibleModelMetadata> _modelMetadata = const [];

  List<OpenAiCompatibleModelMetadata> get modelMetadata => _modelMetadata;

  static Uri normalizeBaseUrl(String value) {
    final uri = Uri.parse(value.trim());
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw FormatException(
        'OpenAI-compatible base URL must be an HTTP(S) URL',
        value,
      );
    }
    if (uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@')) {
      throw FormatException(
        'OpenAI-compatible base URL must not contain credentials, query, or fragment',
        value,
      );
    }

    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    if (uri.path.endsWith('/chat/completions') ||
        uri.path.endsWith('/responses')) {
      throw FormatException(
        'Enter the API root, removing /chat/completions or /responses',
        value,
      );
    }
    return uri.replace(pathSegments: segments);
  }

  /// Verifies reachability without generating content or requiring discovery.
  /// A missing root route still establishes reachability, not model support.
  Future<void> probeReachability() async {
    final request = http.Request('HEAD', _endpoint(''))
      ..followRedirects = false
      ..headers.addAll(_headers);
    final response = await _client.send(request).timeout(requestTimeout);
    await response.stream.drain<void>().timeout(requestTimeout);
    if (!((response.statusCode >= 200 && response.statusCode < 300) ||
        response.statusCode == 404 ||
        response.statusCode == 405)) {
      throw OllamaHttpException(
        endpoint: request.url,
        statusCode: response.statusCode,
        body: 'Server reachability check failed.',
      );
    }
  }

  Future<List<String>> listModels() async {
    final endpoint = _endpoint('models');
    final request = http.Request('GET', endpoint)..headers.addAll(_headers);
    try {
      final json = await _sendUnary(request);
      final data = json['data'];
      if (data is! List) {
        throw const OllamaProtocolException('Missing OpenAI models array');
      }
      final models = <OpenAiCompatibleModelMetadata>[];
      final seen = <String>{};
      for (final value in data) {
        final item = _object(value, 'OpenAI model');
        final id = item['id'];
        if (id is! String || id.trim().isEmpty) {
          throw const OllamaProtocolException('Invalid OpenAI model id');
        }
        Set<String>? capabilities;
        if (item.containsKey('capabilities')) {
          final rawCapabilities = item['capabilities'];
          if (rawCapabilities is! List ||
              rawCapabilities.any(
                (value) => value is! String || value.trim().isEmpty,
              )) {
            throw const OllamaProtocolException(
              'Invalid OpenAI model capabilities',
            );
          }
          capabilities = Set<String>.unmodifiable(
            rawCapabilities.cast<String>().map((value) => value.trim()),
          );
        }
        if (seen.add(id)) {
          models.add(
            OpenAiCompatibleModelMetadata(id: id, capabilities: capabilities),
          );
        }
      }
      _modelMetadata = List<OpenAiCompatibleModelMetadata>.unmodifiable(models);
      return List<String>.unmodifiable(models.map((model) => model.id));
    } on OllamaException {
      rethrow;
    } on TimeoutException catch (error) {
      throw OllamaTransportException(
        'OpenAI-compatible request timed out',
        cause: error,
      );
    } on http.ClientException catch (error) {
      throw OllamaTransportException(
        'OpenAI-compatible connection failed',
        cause: error,
      );
    } on FormatException catch (error) {
      throw OllamaProtocolException(
        'Invalid OpenAI-compatible JSON response',
        cause: error,
      );
    }
  }

  OllamaChatStream startChat(OllamaChatRequest request) {
    _validateChatRequest(request);
    final requestClient = _streamingClientFactory();
    if (identical(requestClient, _client)) {
      throw ArgumentError(
        'streamingClientFactory must return a request-scoped client',
      );
    }
    if (_claimedStreamingClients[requestClient] == true) {
      requestClient.close();
      throw ArgumentError(
        'streamingClientFactory must return a fresh client for every request',
      );
    }
    _claimedStreamingClients[requestClient] = true;

    final cancellation = _OpenAiCancellation(requestClient);
    return OllamaChatStream.requestScoped(
      stream: _chat(request, cancellation),
      isCancelled: () => cancellation.isCancelled,
      onCancel: () async => cancellation.cancel(),
    );
  }

  Stream<OllamaChatChunk> _chat(
    OllamaChatRequest chatRequest,
    _OpenAiCancellation cancellation,
  ) async* {
    final responses =
        connectionOptions.compatibleApi == CompatibleApi.responses;
    final endpoint = _endpoint(responses ? 'responses' : 'chat/completions');
    final options = chatRequest.validatedOptions;
    final request = http.Request('POST', endpoint)
      ..followRedirects = false
      ..headers.addAll(_headers)
      ..body = jsonEncode(
        responses
            ? ResponsesCodec.request(chatRequest, _imageDataUrl)
            : {
                'model': chatRequest.model,
                'messages': chatRequest.messages.map(_messageJson).toList(),
                'stream': true,
                if (chatRequest.tools.isNotEmpty)
                  'tools': chatRequest.tools
                      .map((tool) => tool.toJson())
                      .toList(),
                if (chatRequest.think case final think?)
                  'reasoning_effort': think ? 'high' : 'none',
                if (options['temperature'] case final value?)
                  'temperature': value,
                if (options['seed'] case final value?) 'seed': value,
                if (options['num_predict'] case final value?)
                  'max_tokens': value,
                if (options['top_p'] case final value?) 'top_p': value,
              },
      );

    try {
      final response = await cancellation.client
          .send(request)
          .timeout(requestTimeout);
      if (cancellation.isCancelled) throw const OllamaCancelledException();

      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await _readBoundedBody(
          response.stream,
          maxBytes: maxErrorBodyBytes,
        ).timeout(requestTimeout);
        throw OllamaHttpException(
          endpoint: endpoint,
          statusCode: response.statusCode,
          body: _redactErrorBody(body.text(allowMalformed: true)),
          bodyTruncated: body.truncated,
        );
      }

      final events = response.stream
          .timeout(streamIdleTimeout)
          .transform(
            SseDataDecoder(
              maxLineBytes: maxSseLineBytes,
              maxEventBytes: maxSseEventBytes,
            ),
          );
      if (responses) {
        final codec = ResponsesCodec(chatRequest.model);
        await for (final event in events) {
          if (cancellation.isCancelled) throw const OllamaCancelledException();
          if (event.data == '[DONE]') continue;
          final chunk = codec.accept(
            _object(jsonDecode(event.data), 'Responses event'),
          );
          if (chunk != null) yield chunk;
        }
        yield codec.finish();
        return;
      }
      OllamaChatChunk? terminalChunk;
      var sawDoneMarker = false;
      final toolCalls = _OpenAiToolCallCollector(
        maxArgumentsBytes: maxSseEventBytes,
      );

      await for (final event in events) {
        if (cancellation.isCancelled) throw const OllamaCancelledException();
        final data = event.data;
        if (data == '[DONE]') {
          if (sawDoneMarker) {
            throw const OllamaStreamException(
              'OpenAI stream emitted more than one [DONE] marker',
            );
          }
          if (terminalChunk == null) {
            throw const OllamaStreamException(
              'OpenAI stream ended before a terminal finish_reason',
            );
          }
          sawDoneMarker = true;
          continue;
        }
        if (sawDoneMarker) {
          throw const OllamaStreamException(
            'OpenAI stream emitted data after its [DONE] marker',
          );
        }

        final json = _object(jsonDecode(data), 'OpenAI stream event');
        final streamError = _streamError(json);
        if (streamError != null) throw OllamaStreamException(streamError);
        if (event.type == 'hermes.tool.progress') {
          if (terminalChunk != null) {
            throw const OllamaStreamException(
              'OpenAI stream emitted progress after its terminal finish_reason',
            );
          }
          yield OllamaChatChunk(
            model: json['model'] is String
                ? json['model'] as String
                : chatRequest.model,
            createdAt: _createdAt(json['created']),
            message: const OllamaChatMessage(
              role: OllamaRole.assistant,
              content: '',
            ),
            done: false,
            toolProgress: _toolProgress(json),
          );
          continue;
        }
        if (event.type != 'message') {
          throw OllamaStreamException(
            'Unsupported OpenAI SSE event: ${event.type}',
          );
        }

        final choices = json['choices'];
        if (choices is! List) {
          throw const OllamaStreamException(
            'OpenAI stream event is missing choices',
          );
        }
        if (choices.isEmpty) continue;

        final indexedChoices = choices
            .where((value) {
              final choice = _object(value, 'OpenAI stream choice');
              return choice['index'] == 0;
            })
            .toList(growable: false);
        if (indexedChoices.length != 1) {
          throw const OllamaStreamException(
            'OpenAI stream must contain exactly one choice at index 0',
          );
        }
        if (terminalChunk != null) {
          throw const OllamaStreamException(
            'OpenAI stream emitted choice data after its terminal finish_reason',
          );
        }

        final choice = _object(indexedChoices.single, 'OpenAI stream choice');
        final delta = _object(choice['delta'], 'OpenAI stream delta');
        if (delta['function_call'] != null) {
          throw const OllamaStreamException(
            'Legacy OpenAI function_call deltas are not supported',
          );
        }
        toolCalls.add(delta['tool_calls']);
        final rawContent = delta['content'];
        if (rawContent != null && rawContent is! String) {
          throw const OllamaStreamException(
            'OpenAI stream content must be text',
          );
        }
        final content = rawContent as String? ?? '';
        final reasoning = _reasoningDelta(delta);
        final rawFinishReason = choice['finish_reason'];
        if (rawFinishReason != null && rawFinishReason is! String) {
          throw const OllamaStreamException(
            'OpenAI finish_reason must be a string',
          );
        }
        final finishReason = rawFinishReason as String?;
        final chunk = OllamaChatChunk(
          model: json['model'] is String
              ? json['model'] as String
              : chatRequest.model,
          createdAt: _createdAt(json['created']),
          message: OllamaChatMessage(
            role: OllamaRole.assistant,
            content: content,
            thinking: reasoning,
            toolCalls: finishReason == null ? const [] : toolCalls.complete(),
          ),
          done: finishReason != null,
          doneReason: finishReason,
        );
        if (chunk.done) {
          terminalChunk = chunk;
        } else if (content.isNotEmpty || reasoning.isNotEmpty) {
          yield chunk;
        }
      }

      if (terminalChunk == null) {
        throw const OllamaStreamException(
          'OpenAI stream ended before a terminal finish_reason',
        );
      }
      if (!sawDoneMarker) {
        throw const OllamaStreamException(
          'OpenAI stream ended before its [DONE] marker',
        );
      }
      yield terminalChunk;
    } on OllamaException {
      rethrow;
    } on SseLimitException catch (error) {
      throw OllamaResponseTooLargeException(
        endpoint: endpoint,
        maxBytes: error.maxBytes,
        kind: error.kind,
        cause: error,
      );
    } on TimeoutException catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaTransportException(
        'OpenAI-compatible request timed out',
        cause: error,
      );
    } on http.ClientException catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaTransportException(
        'OpenAI-compatible connection failed',
        cause: error,
      );
    } on FormatException catch (error) {
      throw OllamaStreamException(
        'Invalid OpenAI-compatible stream',
        cause: error,
      );
    } catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaStreamException(
        'OpenAI-compatible stream failed',
        cause: error,
      );
    } finally {
      cancellation.close();
    }
  }

  Future<Map<String, dynamic>> _sendUnary(http.Request request) async {
    request.followRedirects = false;
    final response = await _client.send(request).timeout(requestTimeout);
    final successful = response.statusCode >= 200 && response.statusCode < 300;
    final body = await _readBoundedBody(
      response.stream,
      maxBytes: successful ? maxResponseBodyBytes : maxErrorBodyBytes,
    ).timeout(requestTimeout);
    if (!successful) {
      throw OllamaHttpException(
        endpoint: request.url,
        statusCode: response.statusCode,
        body: _redactErrorBody(body.text(allowMalformed: true)),
        bodyTruncated: body.truncated,
      );
    }
    if (body.truncated) {
      throw OllamaResponseTooLargeException(
        endpoint: request.url,
        maxBytes: maxResponseBodyBytes,
        kind: 'response body',
      );
    }
    return _object(jsonDecode(body.text()), 'OpenAI response');
  }

  void _validateChatRequest(OllamaChatRequest request) {
    final options = request.validatedOptions;
    if (request.model.trim().isEmpty) {
      throw const OllamaProtocolException('Model name must not be empty');
    }
    final maxTokens = options['num_predict'];
    if (maxTokens is int && maxTokens < 1) {
      throw const OllamaProtocolException(
        'OpenAI-compatible max_tokens must be a positive integer',
      );
    }
    for (final message in request.messages) {
      if (message.images.isNotEmpty && message.role != OllamaRole.user) {
        throw const OllamaProtocolException(
          'OpenAI-compatible image parts require a user message',
        );
      }
      if (message.thinking.isNotEmpty && message.role != OllamaRole.assistant) {
        throw const OllamaProtocolException(
          'OpenAI-compatible reasoning requires an assistant message',
        );
      }
      if (message.toolCalls.isNotEmpty &&
          message.role != OllamaRole.assistant) {
        throw const OllamaProtocolException(
          'OpenAI-compatible tool calls require an assistant message',
        );
      }
      if (message.role == OllamaRole.tool) {
        if (message.toolCallId == null || message.toolCallId!.trim().isEmpty) {
          throw const OllamaProtocolException(
            'OpenAI-compatible tool results require tool_call_id',
          );
        }
      } else if (message.toolCallId != null) {
        throw const OllamaProtocolException(
          'OpenAI-compatible tool_call_id requires a tool message',
        );
      }
      for (final call in message.toolCalls) {
        if (call.id == null || call.id!.trim().isEmpty) {
          throw const OllamaProtocolException(
            'OpenAI-compatible assistant tool calls require an id',
          );
        }
        if (call.name.trim().isEmpty) {
          throw const OllamaProtocolException(
            'OpenAI-compatible assistant tool calls require a function name',
          );
        }
      }
    }
  }

  Map<String, String> get _headers => connectionOptions.headers;

  Map<String, dynamic> _messageJson(OllamaChatMessage message) {
    if (message.role == OllamaRole.tool) {
      return {
        'role': 'tool',
        'content': message.content,
        'tool_call_id': message.toolCallId,
      };
    }
    return {
      'role': message.role.name,
      'content': message.images.isEmpty
          ? message.content
          : [
              if (message.content.isNotEmpty)
                {'type': 'text', 'text': message.content},
              for (final image in message.images)
                {
                  'type': 'image_url',
                  'image_url': {'url': _imageDataUrl(image)},
                },
            ],
      if (message.thinking.isNotEmpty) 'reasoning_content': message.thinking,
      if (message.toolCalls.isNotEmpty)
        'tool_calls': [
          for (final call in message.toolCalls)
            {
              'id': call.id,
              'type': 'function',
              'function': {
                'name': call.name,
                'arguments': jsonEncode(call.arguments),
              },
            },
        ],
    };
  }

  String _imageDataUrl(String encoded) {
    late final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException catch (error) {
      throw OllamaProtocolException(
        'OpenAI-compatible image is not valid base64',
        cause: error,
      );
    }
    final mediaType = switch (bytes) {
      [0xff, 0xd8, 0xff, ...] => 'image/jpeg',
      [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...] => 'image/png',
      [0x47, 0x49, 0x46, 0x38, 0x37, 0x61, ...] ||
      [0x47, 0x49, 0x46, 0x38, 0x39, 0x61, ...] => 'image/gif',
      [0x52, 0x49, 0x46, 0x46, _, _, _, _, 0x57, 0x45, 0x42, 0x50, ...] =>
        'image/webp',
      _ => throw const OllamaProtocolException(
        'OpenAI-compatible images must be JPEG, PNG, GIF, or WebP',
      ),
    };
    return 'data:$mediaType;base64,$encoded';
  }

  Uri _endpoint(String path) {
    return connectionOptions.endpoint(baseUri, path);
  }

  String _redactErrorBody(String raw) {
    return connectionOptions.redact(raw);
  }

  static String _reasoningDelta(Map<String, dynamic> delta) {
    final reasoningContent = delta['reasoning_content'];
    final reasoning = delta['reasoning'];
    if (reasoningContent != null && reasoningContent is! String) {
      throw const OllamaStreamException(
        'OpenAI reasoning_content delta must be text',
      );
    }
    if (reasoning != null && reasoning is! String) {
      throw const OllamaStreamException('OpenAI reasoning delta must be text');
    }
    if (reasoningContent is String &&
        reasoning is String &&
        reasoningContent.isNotEmpty &&
        reasoning.isNotEmpty &&
        reasoningContent != reasoning) {
      throw const OllamaStreamException(
        'OpenAI stream emitted conflicting reasoning fields',
      );
    }
    return (reasoningContent as String?) ?? (reasoning as String?) ?? '';
  }

  static OllamaToolProgress _toolProgress(Map<String, dynamic> json) {
    String? optionalString(String key) {
      final value = json[key];
      if (value == null) return null;
      if (value is! String) {
        throw OllamaStreamException('Hermes tool progress $key must be text');
      }
      return value;
    }

    final progress = OllamaToolProgress(
      raw: json,
      toolCallId: optionalString('toolCallId'),
      tool: optionalString('tool') ?? optionalString('name'),
      label: optionalString('label'),
      emoji: optionalString('emoji'),
      status: optionalString('status'),
    );
    if (progress.toolCallId == null &&
        progress.tool == null &&
        progress.label == null &&
        progress.emoji == null &&
        progress.status == null) {
      throw const OllamaStreamException(
        'Hermes tool progress event has no activity data',
      );
    }
    return progress;
  }

  String? _streamError(Map<String, dynamic> json) {
    final error = json['error'];
    if (error == null) return null;
    String detail;
    if (error is String) {
      detail = error;
    } else if (error is Map && error['message'] is String) {
      detail = error['message'] as String;
    } else {
      detail = 'OpenAI-compatible stream returned an error';
    }
    detail = _redactErrorBody(detail)
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return detail.length <= 1000 ? detail : detail.substring(0, 1000);
  }

  static DateTime? _createdAt(Object? value) {
    if (value is! int) return null;
    return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
  }

  static Map<String, dynamic> _object(Object? value, String label) {
    if (value is! Map) throw FormatException('$label must be an object');
    return Map<String, dynamic>.from(value);
  }
}

final class OpenAiCompatibleModelMetadata {
  OpenAiCompatibleModelMetadata({
    required this.id,
    required Set<String>? capabilities,
  }) : capabilities = capabilities == null
           ? null
           : Set<String>.unmodifiable(capabilities);

  final String id;
  final Set<String>? capabilities;
}

final class _OpenAiToolCallCollector {
  _OpenAiToolCallCollector({required this.maxArgumentsBytes});

  static const int _maxCalls = 128;

  final int maxArgumentsBytes;
  final Map<int, _OpenAiToolCallBuilder> _byIndex = {};
  final Map<String, int> _indexById = {};
  var _nextSyntheticIndex = 0;

  void add(Object? rawCalls) {
    if (rawCalls == null) return;
    if (rawCalls is! List) {
      throw const OllamaStreamException(
        'OpenAI tool_calls delta must be an array',
      );
    }
    for (final rawCall in rawCalls) {
      final call = OpenAiCompatibleClient._object(
        rawCall,
        'OpenAI tool call delta',
      );
      final rawIndex = call['index'];
      if (rawIndex != null && (rawIndex is! int || rawIndex < 0)) {
        throw const OllamaStreamException(
          'OpenAI tool call index must be a non-negative integer',
        );
      }
      final rawId = call['id'];
      if (rawId != null && (rawId is! String || rawId.isEmpty)) {
        throw const OllamaStreamException(
          'OpenAI tool call id must be non-empty text',
        );
      }
      final id = rawId as String?;
      final index = _resolveIndex(rawIndex as int?, id);
      final builder = _byIndex.putIfAbsent(index, () {
        if (_byIndex.length >= _maxCalls) {
          throw const OllamaStreamException(
            'OpenAI stream emitted too many tool calls',
          );
        }
        return _OpenAiToolCallBuilder(
          index: index,
          maxArgumentsBytes: maxArgumentsBytes,
        );
      });
      builder.add(call);
      if (builder.id case final builderId?) {
        final otherIndex = _indexById[builderId];
        if (otherIndex != null && otherIndex != index) {
          throw const OllamaStreamException(
            'OpenAI stream reused a tool call id',
          );
        }
        _indexById[builderId] = index;
      }
    }
  }

  int _resolveIndex(int? index, String? id) {
    final idIndex = id == null ? null : _indexById[id];
    if (index != null) {
      if (idIndex != null && idIndex != index) {
        throw const OllamaStreamException('OpenAI tool call id changed index');
      }
      if (index >= _nextSyntheticIndex) _nextSyntheticIndex = index + 1;
      return index;
    }
    if (idIndex != null) return idIndex;
    if (id == null) {
      throw const OllamaStreamException(
        'OpenAI tool call delta requires an index or id',
      );
    }
    while (_byIndex.containsKey(_nextSyntheticIndex)) {
      _nextSyntheticIndex++;
    }
    return _nextSyntheticIndex++;
  }

  List<OllamaToolCall> complete() {
    final indices = _byIndex.keys.toList()..sort();
    return List<OllamaToolCall>.unmodifiable(
      indices.map((index) => _byIndex[index]!.complete()),
    );
  }
}

final class _OpenAiToolCallBuilder {
  _OpenAiToolCallBuilder({
    required this.index,
    required this.maxArgumentsBytes,
  });

  final int index;
  final int maxArgumentsBytes;
  final StringBuffer _arguments = StringBuffer();
  var _argumentsBytes = 0;
  String? id;
  String? name;

  void add(Map<String, dynamic> call) {
    final type = call['type'];
    if (type != null && type != 'function') {
      throw OllamaStreamException('Unsupported OpenAI tool call type: $type');
    }
    final rawId = call['id'];
    if (rawId is String) {
      if (id != null && id != rawId) {
        throw OllamaStreamException('OpenAI tool call index $index changed id');
      }
      id = rawId;
    }
    final rawFunction = call['function'];
    if (rawFunction == null) return;
    final function = OpenAiCompatibleClient._object(
      rawFunction,
      'OpenAI tool call function delta',
    );
    final rawName = function['name'];
    if (rawName != null && rawName is! String) {
      throw const OllamaStreamException('OpenAI tool call name must be text');
    }
    if (rawName is String && rawName.isNotEmpty) {
      if (name != null && name != rawName) {
        throw OllamaStreamException(
          'OpenAI tool call index $index changed function name',
        );
      }
      name = rawName;
    }
    final rawArguments = function['arguments'];
    if (rawArguments != null && rawArguments is! String) {
      throw const OllamaStreamException(
        'OpenAI tool call arguments delta must be text',
      );
    }
    if (rawArguments is String && rawArguments.isNotEmpty) {
      final bytes = utf8.encode(rawArguments).length;
      if (_argumentsBytes + bytes > maxArgumentsBytes) {
        throw SseLimitException('tool call arguments', maxArgumentsBytes);
      }
      _argumentsBytes += bytes;
      _arguments.write(rawArguments);
    }
  }

  OllamaToolCall complete() {
    if (id == null || id!.isEmpty) {
      throw OllamaStreamException(
        'OpenAI tool call index $index is missing an id',
      );
    }
    if (name == null || name!.isEmpty) {
      throw OllamaStreamException(
        'OpenAI tool call index $index is missing a function name',
      );
    }
    final rawArguments = _arguments.toString();
    if (rawArguments.isEmpty) {
      throw OllamaStreamException(
        'OpenAI tool call index $index is missing function arguments',
      );
    }
    late final Object? decoded;
    try {
      decoded = jsonDecode(rawArguments);
    } on FormatException catch (error) {
      throw OllamaStreamException(
        'OpenAI tool call index $index has invalid JSON arguments',
        cause: error,
      );
    }
    if (decoded is! Map) {
      throw OllamaStreamException(
        'OpenAI tool call index $index arguments must be a JSON object',
      );
    }
    return OllamaToolCall(
      index: index,
      id: id,
      name: name!,
      arguments: Map<String, dynamic>.from(decoded),
    );
  }
}

final class _OpenAiCancellation {
  _OpenAiCancellation(this.client);

  final http.Client client;
  bool isCancelled = false;
  bool _closed = false;

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    close();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    client.close();
  }
}

Future<_OpenAiBoundedBody> _readBoundedBody(
  Stream<List<int>> stream, {
  required int maxBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    final remaining = maxBytes - bytes.length;
    if (chunk.length > remaining) {
      if (remaining > 0) bytes.add(chunk.sublist(0, remaining));
      return _OpenAiBoundedBody(bytes.takeBytes(), truncated: true);
    }
    bytes.add(chunk);
  }
  return _OpenAiBoundedBody(bytes.takeBytes(), truncated: false);
}

final class _OpenAiBoundedBody {
  const _OpenAiBoundedBody(this.bytes, {required this.truncated});

  final Uint8List bytes;
  final bool truncated;

  String text({bool allowMalformed = false}) =>
      utf8.decode(bytes, allowMalformed: allowMalformed);
}
