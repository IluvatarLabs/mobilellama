import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'ndjson_decoder.dart';

typedef HttpClientFactory = http.Client Function();
typedef OllamaChatStarter = OllamaChatStream Function(
  OllamaChatRequest request,
);

final class OllamaClient {
  static final Expando<bool> _claimedStreamingClients = Expando<bool>();

  OllamaClient({
    required String baseUrl,
    required http.Client client,
    HttpClientFactory? streamingClientFactory,
    this.requestTimeout = const Duration(seconds: 15),
    this.streamIdleTimeout = const Duration(minutes: 2),
    this.maxResponseBodyBytes = 4 * 1024 * 1024,
    this.maxErrorBodyBytes = 16 * 1024,
    this.maxNdjsonLineBytes = 1024 * 1024,
  }) : baseUri = normalizeBaseUrl(baseUrl),
       _client = client,
       _streamingClientFactory = streamingClientFactory ?? http.Client.new {
    if (maxResponseBodyBytes < 1 ||
        maxErrorBodyBytes < 1 ||
        maxNdjsonLineBytes < 1) {
      throw ArgumentError('Ollama response bounds must be positive');
    }
  }

  final Uri baseUri;
  final http.Client _client;
  final HttpClientFactory _streamingClientFactory;
  final Duration requestTimeout;
  final Duration streamIdleTimeout;
  final int maxResponseBodyBytes;
  final int maxErrorBodyBytes;
  final int maxNdjsonLineBytes;

  static Uri normalizeBaseUrl(String value) {
    final uri = Uri.parse(value.trim());
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw FormatException('Ollama base URL must be an HTTP(S) URL', value);
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      throw FormatException(
        'Ollama base URL must not contain credentials, query, or fragment',
        value,
      );
    }

    final path = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .join('/');
    return uri.replace(path: path.isEmpty ? '' : '/$path');
  }

  Future<OllamaVersion> getVersion() async {
    final json = await _getJson('/api/version');
    return OllamaVersion.fromJson(json);
  }

  Future<List<OllamaModelSummary>> listModels() async {
    final json = await _getJson('/api/tags');
    final models = json['models'];
    if (models is! List) {
      throw const OllamaProtocolException('Missing models array');
    }
    try {
      return models
          .map((value) => OllamaModelSummary.fromJson(_jsonObject(value)))
          .toList(growable: false);
    } on FormatException catch (error) {
      throw OllamaProtocolException('Invalid model list', cause: error);
    }
  }

  /// Fetches capabilities for the model the caller selected. Model listing does
  /// not fan out this request across every installed model.
  Future<OllamaShowResponse> showModel(String model) async {
    if (model.trim().isEmpty) {
      throw const OllamaProtocolException('Model name must not be empty');
    }
    final json = await _postJson('/api/show', {'model': model});
    try {
      return OllamaShowResponse.fromJson(json);
    } on FormatException catch (error) {
      throw OllamaProtocolException('Invalid model details', cause: error);
    }
  }

  /// Deletes an installed model from this Ollama server.
  Future<void> deleteModel(String model) async {
    final normalizedModel = _validatedManagedModelName(model);
    final endpoint = _endpoint('/api/delete');
    final request = http.Request('DELETE', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': normalizedModel});
    try {
      await _sendBounded(request);
    } on OllamaException {
      rethrow;
    } on TimeoutException catch (error) {
      throw OllamaTransportException('Ollama request timed out', cause: error);
    } on http.ClientException catch (error) {
      throw OllamaTransportException('Ollama connection failed', cause: error);
    }
  }

  /// Starts one request-scoped model pull stream.
  OllamaModelPull startModelPull(String model) {
    final normalizedModel = _validatedManagedModelName(model);
    final cancellation = _claimStreamingClient();
    return OllamaModelPull.requestScoped(
      stream: _pullModel(normalizedModel, cancellation),
      isCancelled: () => cancellation.isCancelled,
      onCancel: () async => cancellation.cancel(),
    );
  }

  /// Starts one request-scoped chat stream.
  ///
  /// The factory must return a fresh client. That client, unlike the injected
  /// shared unary client, is closed on completion, error, or [OllamaChatStream.cancel].
  OllamaChatStream startChat(OllamaChatRequest request) {
    request.validatedOptions;
    final cancellation = _claimStreamingClient();
    return OllamaChatStream.requestScoped(
      stream: _chat(request, cancellation),
      isCancelled: () => cancellation.isCancelled,
      onCancel: () async => cancellation.cancel(),
    );
  }

  _StreamingCancellation _claimStreamingClient() {
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
    return _StreamingCancellation(requestClient);
  }

  Stream<OllamaChatChunk> _chat(
    OllamaChatRequest chatRequest,
    _StreamingCancellation cancellation,
  ) async* {
    final endpoint = _endpoint('/api/chat');
    final request = http.Request('POST', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode(chatRequest.toJson()..['stream'] = true);

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
          body: body.text(allowMalformed: true),
          bodyTruncated: body.truncated,
        );
      }

      final source = response.stream.timeout(streamIdleTimeout);
      OllamaChatChunk? terminalChunk;
      await for (final json in source.transform(
        NdjsonDecoder(maxLineBytes: maxNdjsonLineBytes),
      )) {
        if (cancellation.isCancelled) throw const OllamaCancelledException();
        if (terminalChunk != null) {
          throw const OllamaStreamException(
            'Ollama stream emitted data after its terminal done response',
          );
        }
        final error = json['error'];
        if (error is String && error.isNotEmpty) {
          throw OllamaStreamException(error);
        }
        final chunk = OllamaChatChunk.fromJson(json);
        if (chunk.done) {
          terminalChunk = chunk;
        } else {
          yield chunk;
        }
      }
      if (terminalChunk == null) {
        throw const OllamaStreamException(
          'Ollama stream ended before a terminal done response',
        );
      }
      // Holding the terminal chunk until EOF lets callers treat a yielded
      // `done` as proof that the response contained exactly one terminal
      // record and no protocol data followed it.
      yield terminalChunk;
    } on OllamaException {
      rethrow;
    } on NdjsonLineTooLongException catch (error) {
      throw OllamaResponseTooLargeException(
        endpoint: endpoint,
        maxBytes: error.maxLineBytes,
        kind: 'NDJSON line',
        cause: error,
      );
    } on NdjsonDecodeException catch (error) {
      throw OllamaStreamException('Invalid Ollama stream', cause: error);
    } on TimeoutException catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaTransportException('Ollama request timed out', cause: error);
    } on http.ClientException catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaTransportException('Ollama connection failed', cause: error);
    } catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaStreamException('Ollama stream failed', cause: error);
    } finally {
      cancellation.close();
    }
  }

  Stream<OllamaModelPullProgress> _pullModel(
    String model,
    _StreamingCancellation cancellation,
  ) async* {
    final endpoint = _endpoint('/api/pull');
    final request = http.Request('POST', endpoint)
      ..headers['Content-Type'] = 'application/json'
      ..body = jsonEncode({'model': model, 'stream': true});

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
          body: body.text(allowMalformed: true),
          bodyTruncated: body.truncated,
        );
      }

      final source = response.stream.timeout(streamIdleTimeout);
      OllamaModelPullProgress? terminalProgress;
      await for (final json in source.transform(
        NdjsonDecoder(maxLineBytes: maxNdjsonLineBytes),
      )) {
        if (cancellation.isCancelled) throw const OllamaCancelledException();
        if (terminalProgress != null) {
          throw const OllamaStreamException(
            'Ollama model pull emitted data after success',
          );
        }
        final error = json['error'];
        if (error is String && error.isNotEmpty) {
          throw OllamaStreamException(error);
        }
        if (error != null) {
          throw const OllamaStreamException(
            'Invalid Ollama model pull error response',
          );
        }
        final progress = OllamaModelPullProgress.fromJson(json);
        if (progress.isSuccess) {
          terminalProgress = progress;
        } else {
          yield progress;
        }
      }
      if (terminalProgress == null) {
        throw const OllamaStreamException(
          'Ollama model pull ended before success',
        );
      }
      yield terminalProgress;
    } on OllamaException {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      rethrow;
    } on NdjsonLineTooLongException catch (error) {
      throw OllamaResponseTooLargeException(
        endpoint: endpoint,
        maxBytes: error.maxLineBytes,
        kind: 'NDJSON line',
        cause: error,
      );
    } on NdjsonDecodeException catch (error) {
      throw OllamaStreamException(
        'Invalid Ollama model pull stream',
        cause: error,
      );
    } on FormatException catch (error) {
      throw OllamaStreamException(
        'Invalid Ollama model pull progress',
        cause: error,
      );
    } on TimeoutException catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaTransportException('Ollama request timed out', cause: error);
    } on http.ClientException catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaTransportException('Ollama connection failed', cause: error);
    } catch (error) {
      if (cancellation.isCancelled) throw const OllamaCancelledException();
      throw OllamaStreamException('Ollama model pull failed', cause: error);
    } finally {
      cancellation.close();
    }
  }

  Future<Map<String, dynamic>> _getJson(String path) async {
    final endpoint = _endpoint(path);
    try {
      final request = http.Request('GET', endpoint);
      return await _sendUnary(request);
    } on OllamaException {
      rethrow;
    } on TimeoutException catch (error) {
      throw OllamaTransportException('Ollama request timed out', cause: error);
    } on http.ClientException catch (error) {
      throw OllamaTransportException('Ollama connection failed', cause: error);
    } on FormatException catch (error) {
      throw OllamaProtocolException(
        'Invalid Ollama JSON response',
        cause: error,
      );
    }
  }

  Future<Map<String, dynamic>> _postJson(
    String path,
    Map<String, dynamic> body,
  ) async {
    final endpoint = _endpoint(path);
    try {
      final request = http.Request('POST', endpoint)
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
      return await _sendUnary(request);
    } on OllamaException {
      rethrow;
    } on TimeoutException catch (error) {
      throw OllamaTransportException('Ollama request timed out', cause: error);
    } on http.ClientException catch (error) {
      throw OllamaTransportException('Ollama connection failed', cause: error);
    } on FormatException catch (error) {
      throw OllamaProtocolException(
        'Invalid Ollama JSON response',
        cause: error,
      );
    }
  }

  Future<Map<String, dynamic>> _sendUnary(http.Request request) async {
    final body = await _sendBounded(request);
    return _jsonObject(jsonDecode(body.text()));
  }

  Future<_BoundedBody> _sendBounded(http.Request request) async {
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
        body: body.text(allowMalformed: true),
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
    return body;
  }

  Uri _endpoint(String path) {
    final baseSegments = baseUri.pathSegments.where((part) => part.isNotEmpty);
    final pathSegments = path.split('/').where((part) => part.isNotEmpty);
    return baseUri.replace(pathSegments: [...baseSegments, ...pathSegments]);
  }

  static String _validatedManagedModelName(String model) {
    final normalized = model.trim();
    if (normalized.isEmpty) {
      throw const OllamaProtocolException('Model name must not be empty');
    }
    const maxModelNameBytes = 512;
    if (utf8.encode(normalized).length > maxModelNameBytes) {
      throw const OllamaProtocolException(
        'Model name exceeds the 512 byte limit',
      );
    }
    return normalized;
  }
}

final class OllamaChatStream {
  OllamaChatStream.requestScoped({
    required this.stream,
    required bool Function() isCancelled,
    required Future<void> Function() onCancel,
  }) : _isCancelled = isCancelled,
       _onCancel = onCancel;

  final Stream<OllamaChatChunk> stream;
  final bool Function() _isCancelled;
  final Future<void> Function() _onCancel;

  bool get isCancelled => _isCancelled();

  Future<void> cancel() => _onCancel();
}

final class OllamaModelPull {
  OllamaModelPull.requestScoped({
    required this.stream,
    required bool Function() isCancelled,
    required Future<void> Function() onCancel,
  }) : _isCancelled = isCancelled,
       _onCancel = onCancel;

  final Stream<OllamaModelPullProgress> stream;
  final bool Function() _isCancelled;
  final Future<void> Function() _onCancel;

  bool get isCancelled => _isCancelled();

  Future<void> cancel() => _onCancel();
}

final class OllamaModelPullProgress {
  const OllamaModelPullProgress({
    required this.status,
    this.digest,
    this.total,
    this.completed,
  });

  final String status;
  final String? digest;
  final int? total;
  final int? completed;

  bool get isSuccess => status == 'success';

  double? get fraction {
    final totalBytes = total;
    final completedBytes = completed;
    if (totalBytes == null || totalBytes == 0 || completedBytes == null) {
      return null;
    }
    return completedBytes / totalBytes;
  }

  factory OllamaModelPullProgress.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    if (status is! String || status.trim().isEmpty) {
      throw const FormatException('Missing model pull status');
    }
    final digest = json['digest'];
    if (digest != null && (digest is! String || digest.isEmpty)) {
      throw const FormatException('Invalid model pull digest');
    }
    final total = json['total'];
    final completed = json['completed'];
    if (total != null && (total is! int || total < 0)) {
      throw const FormatException('Invalid model pull total');
    }
    if (completed != null && (completed is! int || completed < 0)) {
      throw const FormatException('Invalid model pull completed count');
    }
    if (total is int && completed is int && total > 0 && completed > total) {
      throw const FormatException(
        'Model pull completed count exceeds its total',
      );
    }
    return OllamaModelPullProgress(
      status: status,
      digest: digest as String?,
      total: total as int?,
      completed: completed as int?,
    );
  }
}

final class _StreamingCancellation {
  _StreamingCancellation(this.client);

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

enum OllamaRole { system, user, assistant, tool }

final class OllamaChatMessage {
  const OllamaChatMessage({
    required this.role,
    required this.content,
    this.thinking = '',
    this.images = const [],
    this.toolCalls = const [],
    this.toolName,
    this.toolCallId,
  });

  final OllamaRole role;
  final String content;
  final String thinking;
  final List<String> images;
  final List<OllamaToolCall> toolCalls;
  final String? toolName;
  final String? toolCallId;

  factory OllamaChatMessage.fromJson(Map<String, dynamic> json) {
    final roleName = json['role'] as String? ?? 'assistant';
    final role = OllamaRole.values.where((value) => value.name == roleName);
    if (role.isEmpty) throw FormatException('Unknown Ollama role: $roleName');

    return OllamaChatMessage(
      role: role.first,
      content: json['content'] as String? ?? '',
      thinking: json['thinking'] as String? ?? '',
      images: _stringList(json['images']),
      toolCalls: _objectList(json['tool_calls'])
          .map(OllamaToolCall.fromJson)
          .toList(growable: false),
      toolName: json['tool_name'] as String?,
      toolCallId: json['tool_call_id'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    'role': role.name,
    'content': content,
    if (thinking.isNotEmpty) 'thinking': thinking,
    if (images.isNotEmpty) 'images': images,
    if (toolCalls.isNotEmpty)
      'tool_calls': toolCalls.map((call) => call.toJson()).toList(),
    if (toolName != null) 'tool_name': toolName,
    if (toolCallId != null) 'tool_call_id': toolCallId,
  };
}

final class OllamaToolCall {
  const OllamaToolCall({
    required this.name,
    required this.arguments,
    this.index,
    this.id,
    this.description,
  });

  final String name;
  final Map<String, dynamic> arguments;
  final int? index;
  final String? id;
  final String? description;

  factory OllamaToolCall.fromJson(Map<String, dynamic> json) {
    final function = _jsonObject(json['function']);
    return OllamaToolCall(
      name: function['name'] as String? ?? '',
      arguments: function['arguments'] == null
          ? const {}
          : _jsonObject(function['arguments']),
      index: (json['index'] ?? function['index']) as int?,
      id: json['id'] as String?,
      description: function['description'] as String?,
    );
  }

  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'function': {
      if (index != null) 'index': index,
      'name': name,
      if (description != null) 'description': description,
      'arguments': arguments,
    },
  };
}

final class OllamaToolDefinition {
  const OllamaToolDefinition({
    required this.name,
    required this.description,
    required this.parameters,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;

  Map<String, dynamic> toJson() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters,
    },
  };
}

final class OllamaChatRequest {
  const OllamaChatRequest({
    required this.model,
    required this.messages,
    this.tools = const [],
    this.think,
    this.options = const {},
  });

  final String model;
  final List<OllamaChatMessage> messages;
  final List<OllamaToolDefinition> tools;
  final bool? think;
  final Map<String, Object> options;

  Map<String, Object> get validatedOptions =>
      _validatedGenerationOptions(options);

  Map<String, dynamic> toJson() => {
    'model': model,
    'messages': messages.map((message) => message.toJson()).toList(),
    if (tools.isNotEmpty) 'tools': tools.map((tool) => tool.toJson()).toList(),
    if (think != null) 'think': think,
    if (validatedOptions.isNotEmpty) 'options': validatedOptions,
  };
}

Map<String, Object> _validatedGenerationOptions(Map<String, Object> options) {
  if (options.isEmpty) return const {};
  const supportedKeys = <String>{
    'temperature',
    'seed',
    'num_predict',
    'num_ctx',
    'repeat_last_n',
    'repeat_penalty',
    'tfs_z',
    'top_k',
    'top_p',
    'min_p',
    'mirostat',
    'mirostat_eta',
    'mirostat_tau',
  };
  for (final key in options.keys) {
    if (!supportedKeys.contains(key)) {
      throw ArgumentError.value(
        key,
        'options',
        'unsupported Ollama generation option',
      );
    }
  }

  void finiteInRange(String key, {required double minimum, double? maximum}) {
    final value = options[key];
    if (value == null) return;
    if (value is! num ||
        !value.isFinite ||
        value < minimum ||
        (maximum != null && value > maximum)) {
      final range = maximum == null
          ? 'at least $minimum'
          : 'from $minimum through $maximum';
      throw ArgumentError.value(value, 'options[$key]', 'must be $range');
    }
  }

  void integerInRange(String key, {required int minimum, int? maximum}) {
    final value = options[key];
    if (value == null) return;
    if (value is! int ||
        value < minimum ||
        (maximum != null && value > maximum)) {
      final range = maximum == null
          ? 'an integer of at least $minimum'
          : 'an integer from $minimum through $maximum';
      throw ArgumentError.value(value, 'options[$key]', 'must be $range');
    }
  }

  finiteInRange('temperature', minimum: 0);
  integerInRange('seed', minimum: 0);
  // Ollama reserves -1 for unlimited generation and -2 for filling the
  // available context window.
  integerInRange('num_predict', minimum: -2);
  integerInRange('num_ctx', minimum: 1);
  // Ollama reserves -1 for the full context and accepts 0 to disable it.
  integerInRange('repeat_last_n', minimum: -1);
  finiteInRange('repeat_penalty', minimum: 0);
  finiteInRange('tfs_z', minimum: 0);
  integerInRange('top_k', minimum: 0);
  finiteInRange('top_p', minimum: 0, maximum: 1);
  finiteInRange('min_p', minimum: 0, maximum: 1);
  integerInRange('mirostat', minimum: 0, maximum: 2);
  finiteInRange('mirostat_eta', minimum: 0);
  finiteInRange('mirostat_tau', minimum: 0);
  return Map<String, Object>.unmodifiable(options);
}

final class OllamaChatChunk {
  const OllamaChatChunk({
    required this.model,
    required this.message,
    required this.done,
    this.createdAt,
    this.doneReason,
    this.promptEvalCount,
    this.evalCount,
    this.toolProgress,
  });

  final String model;
  final DateTime? createdAt;
  final OllamaChatMessage message;
  final bool done;
  final String? doneReason;
  final int? promptEvalCount;
  final int? evalCount;
  final OllamaToolProgress? toolProgress;

  factory OllamaChatChunk.fromJson(Map<String, dynamic> json) {
    final createdAt = json['created_at'] as String?;
    return OllamaChatChunk(
      model: json['model'] as String? ?? '',
      createdAt: createdAt == null ? null : DateTime.tryParse(createdAt),
      message: OllamaChatMessage.fromJson(_jsonObject(json['message'])),
      done: json['done'] as bool? ?? false,
      doneReason: json['done_reason'] as String?,
      promptEvalCount: json['prompt_eval_count'] as int?,
      evalCount: json['eval_count'] as int?,
    );
  }
}

/// Provider-owned tool lifecycle data received outside assistant answer text.
final class OllamaToolProgress {
  OllamaToolProgress({
    required Map<String, dynamic> raw,
    this.toolCallId,
    this.tool,
    this.label,
    this.emoji,
    this.status,
  }) : raw = Map<String, dynamic>.unmodifiable(raw);

  final String? toolCallId;
  final String? tool;
  final String? label;
  final String? emoji;
  final String? status;
  final Map<String, dynamic> raw;
}

final class OllamaVersion {
  const OllamaVersion(this.version);

  final String version;

  factory OllamaVersion.fromJson(Map<String, dynamic> json) {
    final version = json['version'];
    if (version is! String || version.isEmpty) {
      throw const OllamaProtocolException('Missing Ollama version');
    }
    return OllamaVersion(version);
  }
}

final class OllamaModelMetadata {
  const OllamaModelMetadata({
    required this.format,
    required this.family,
    required this.families,
    required this.parameterSize,
    required this.quantizationLevel,
  });

  final String format;
  final String family;
  final List<String> families;
  final String parameterSize;
  final String quantizationLevel;

  factory OllamaModelMetadata.fromJson(Map<String, dynamic> json) =>
      OllamaModelMetadata(
        format: json['format'] as String? ?? '',
        family: json['family'] as String? ?? '',
        families: _stringList(json['families']),
        parameterSize: json['parameter_size'] as String? ?? '',
        quantizationLevel: json['quantization_level'] as String? ?? '',
      );
}

final class OllamaModelSummary {
  const OllamaModelSummary({
    required this.name,
    required this.model,
    required this.modifiedAt,
    required this.size,
    required this.digest,
    required this.details,
  });

  final String name;
  final String model;
  final DateTime? modifiedAt;
  final int size;
  final String digest;
  final OllamaModelMetadata details;

  factory OllamaModelSummary.fromJson(Map<String, dynamic> json) =>
      OllamaModelSummary(
        name: json['name'] as String? ?? '',
        model: json['model'] as String? ?? '',
        modifiedAt: DateTime.tryParse(json['modified_at'] as String? ?? ''),
        size: json['size'] as int? ?? 0,
        digest: json['digest'] as String? ?? '',
        details: OllamaModelMetadata.fromJson(
          json['details'] == null ? const {} : _jsonObject(json['details']),
        ),
      );
}

final class OllamaShowResponse {
  OllamaShowResponse({
    required this.capabilities,
    required this.details,
    required this.modelInfo,
    required this.parameters,
    required this.template,
    required this.license,
  });

  final Set<String> capabilities;
  final OllamaModelMetadata details;
  final Map<String, dynamic> modelInfo;
  final String parameters;
  final String template;
  final String license;

  bool get supportsVision => capabilities.contains('vision');
  bool get supportsThinking => capabilities.contains('thinking');
  bool get supportsTools => capabilities.contains('tools');

  factory OllamaShowResponse.fromJson(Map<String, dynamic> json) =>
      OllamaShowResponse(
        capabilities: _stringList(json['capabilities']).toSet(),
        details: OllamaModelMetadata.fromJson(
          json['details'] == null ? const {} : _jsonObject(json['details']),
        ),
        modelInfo: json['model_info'] == null
            ? const {}
            : _jsonObject(json['model_info']),
        parameters: json['parameters'] as String? ?? '',
        template: json['template'] as String? ?? '',
        license: json['license'] as String? ?? '',
      );
}

sealed class OllamaException implements Exception {
  const OllamaException(this.message, {this.cause});

  final String message;
  final Object? cause;

  @override
  String toString() => message;
}

final class OllamaHttpException extends OllamaException {
  OllamaHttpException({
    required this.endpoint,
    required this.statusCode,
    required this.body,
    this.bodyTruncated = false,
  }) : super(_httpMessage(statusCode, body, bodyTruncated: bodyTruncated));

  final Uri endpoint;
  final int statusCode;
  final String body;
  final bool bodyTruncated;

  static String _httpMessage(
    int statusCode,
    String body, {
    required bool bodyTruncated,
  }) {
    String detail = body;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final candidate = decoded['error'] ?? decoded['message'];
        if (candidate is String) detail = candidate;
      }
    } on FormatException {
      // A bounded plain-text body is still useful diagnostic detail.
    }
    detail = detail
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    const visibleLimit = 1000;
    if (detail.length > visibleLimit) {
      detail = detail.substring(0, visibleLimit);
      bodyTruncated = true;
    }
    if (bodyTruncated) {
      detail = detail.isEmpty ? '[truncated]' : '$detail [truncated]';
    }
    return detail.isEmpty
        ? 'Ollama returned HTTP $statusCode'
        : 'Ollama returned HTTP $statusCode: $detail';
  }
}

final class OllamaTransportException extends OllamaException {
  const OllamaTransportException(super.message, {super.cause});
}

final class OllamaProtocolException extends OllamaException {
  const OllamaProtocolException(super.message, {super.cause});
}

final class OllamaResponseTooLargeException extends OllamaException {
  OllamaResponseTooLargeException({
    required this.endpoint,
    required this.maxBytes,
    required this.kind,
    super.cause,
  }) : super('$kind exceeds the $maxBytes byte limit');

  final Uri endpoint;
  final int maxBytes;
  final String kind;
}

final class OllamaStreamException extends OllamaException {
  const OllamaStreamException(super.message, {super.cause});
}

final class OllamaCancelledException extends OllamaException {
  const OllamaCancelledException() : super('Ollama request cancelled');
}

Map<String, dynamic> _jsonObject(Object? value) {
  if (value is! Map) throw const FormatException('Expected a JSON object');
  return Map<String, dynamic>.from(value);
}

List<Map<String, dynamic>> _objectList(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('Expected a JSON array');
  return value.map(_jsonObject).toList(growable: false);
}

List<String> _stringList(Object? value) {
  if (value == null) return const [];
  if (value is! List) throw const FormatException('Expected a JSON array');
  return value
      .map((item) {
        if (item is! String) throw const FormatException('Expected a string');
        return item;
      })
      .toList(growable: false);
}

Future<_BoundedBody> _readBoundedBody(
  Stream<List<int>> stream, {
  required int maxBytes,
}) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in stream) {
    final remaining = maxBytes - bytes.length;
    if (chunk.length > remaining) {
      if (remaining > 0) bytes.add(chunk.sublist(0, remaining));
      return _BoundedBody(bytes.takeBytes(), truncated: true);
    }
    bytes.add(chunk);
  }
  return _BoundedBody(bytes.takeBytes(), truncated: false);
}

final class _BoundedBody {
  const _BoundedBody(this.bytes, {required this.truncated});

  final Uint8List bytes;
  final bool truncated;

  String text({bool allowMalformed = false}) {
    return utf8.decode(bytes, allowMalformed: allowMalformed);
  }
}
