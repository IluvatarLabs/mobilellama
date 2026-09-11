import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/ollama/ollama_client.dart';
import 'package:mobollama/ollama/openai_compatible_client.dart';

void main() {
  const completion =
      'data: {"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}\n\n'
      'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
      'data: [DONE]\n\n';

  test(
    'blank key omits auth and model metadata remains explicitly nullable',
    () async {
      http.Request? modelsRequest;
      final client = OpenAiCompatibleClient(
        baseUrl: 'https://example.test/v1',
        apiKey: '  ',
        client: MockClient((request) async {
          modelsRequest = request;
          return http.Response(
            '{"data":['
            '{"id":"declared","capabilities":["vision","tools"]},'
            '{"id":"unknown"}]}',
            200,
          );
        }),
      );

      expect(await client.listModels(), ['declared', 'unknown']);
      expect(modelsRequest!.headers['Authorization'], isNull);
      expect(client.modelMetadata[0].id, 'declared');
      expect(client.modelMetadata[0].capabilities, {'vision', 'tools'});
      expect(client.modelMetadata[1].capabilities, isNull);
    },
  );

  test(
    'serializes text, image data URLs, tool calls, and matching results',
    () async {
      const png =
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDw'
          'AEhQGAhKmMIQAAAABJRU5ErkJggg==';
      final fixture = _StreamFixture(completion);

      await fixture
          .start(
            const OllamaChatRequest(
              model: 'test',
              messages: [
                OllamaChatMessage(
                  role: OllamaRole.user,
                  content: 'Look',
                  images: [png],
                ),
                OllamaChatMessage(
                  role: OllamaRole.assistant,
                  content: '',
                  thinking: 'Need a lookup.',
                  toolCalls: [
                    OllamaToolCall(
                      index: 0,
                      id: 'call_search',
                      name: 'web_search',
                      arguments: {'query': 'llamas'},
                    ),
                  ],
                ),
                OllamaChatMessage(
                  role: OllamaRole.tool,
                  content: '{"results":[]}',
                  toolName: 'web_search',
                  toolCallId: 'call_search',
                ),
              ],
              think: true,
              options: {'num_ctx': 4096},
            ),
          )
          .toList();

      expect(fixture.request!.headers['Authorization'], 'Bearer test-key');
      final body = jsonDecode(fixture.body!) as Map<String, dynamic>;
      expect(body['reasoning_effort'], 'high');
      expect(body.containsKey('num_ctx'), isFalse);
      final messages = body['messages'] as List;
      expect(messages[0]['content'], [
        {'type': 'text', 'text': 'Look'},
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/png;base64,$png'},
        },
      ]);
      expect(messages[1]['reasoning_content'], 'Need a lookup.');
      expect(messages[1]['tool_calls'], [
        {
          'id': 'call_search',
          'type': 'function',
          'function': {'name': 'web_search', 'arguments': '{"query":"llamas"}'},
        },
      ]);
      expect(messages[2], {
        'role': 'tool',
        'content': '{"results":[]}',
        'tool_call_id': 'call_search',
      });
    },
  );

  test('preserves fragmented reasoning variants', () async {
    final chunks = await _StreamFixture(
      'data: {"choices":[{"index":0,"delta":{"reasoning_content":"plan "},"finish_reason":null}]}\n\n'
      'data: {"choices":[{"index":0,"delta":{"reasoning":"next"},"finish_reason":null}]}\n\n'
      'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
      'data: [DONE]\n\n',
    ).start(_request).toList();

    expect(chunks.map((chunk) => chunk.message.thinking).join(), 'plan next');
    expect(chunks.map((chunk) => chunk.message.content).join(), isEmpty);
    expect(chunks.last.done, isTrue);
  });

  test(
    'reconstructs multiple fragmented function tool calls by index and id',
    () async {
      String frame(Map<String, dynamic> delta, String? finishReason) =>
          'data: ${jsonEncode({
            'model': 'test',
            'choices': [
              {'index': 0, 'delta': delta, 'finish_reason': finishReason},
            ],
          })}\n\n';
      final stream =
          frame({
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_search',
                'type': 'function',
                'function': {'name': 'web_search', 'arguments': '{"query":"ol'},
              },
              {
                'index': 1,
                'id': 'call_fetch',
                'type': 'function',
                'function': {
                  'name': 'web_fetch',
                  'arguments': '{"url":"https://',
                },
              },
            ],
          }, null) +
          frame({
            'tool_calls': [
              {
                'index': 0,
                'function': {'arguments': 'lama"}'},
              },
              {
                'id': 'call_fetch',
                'function': {'arguments': 'example.test"}'},
              },
            ],
          }, null) +
          frame({}, 'tool_calls') +
          'data: [DONE]\n\n';
      final bytes = utf8.encode(stream);
      final chunks = await _StreamFixture.fromChunks([
        bytes.sublist(0, 13),
        bytes.sublist(13, 71),
        bytes.sublist(71, bytes.length - 5),
        bytes.sublist(bytes.length - 5),
      ]).start(_request).toList();

      expect(chunks, hasLength(1));
      expect(chunks.single.doneReason, 'tool_calls');
      final calls = chunks.single.message.toolCalls;
      expect(calls.map((call) => call.id), ['call_search', 'call_fetch']);
      expect(calls.map((call) => call.name), ['web_search', 'web_fetch']);
      expect(calls[0].arguments, {'query': 'ollama'});
      expect(calls[1].arguments, {'url': 'https://example.test'});
    },
  );

  test('Hermes progress remains visible activity beside answer text', () async {
    final chunks = await _StreamFixture(
      'data: {"choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}\n\n'
      'event: hermes.tool.progress\n'
      'data: {"tool":"web_search","label":"Searching","emoji":"🔎","toolCallId":"call_1","status":"running"}\n\n'
      'data: {"choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}\n\n'
      'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
      'data: [DONE]\n\n',
    ).start(_request).toList();

    expect(chunks.map((chunk) => chunk.message.content).join(), 'Hello');
    final progress = chunks
        .singleWhere((chunk) => chunk.toolProgress != null)
        .toolProgress!;
    expect(progress.toolCallId, 'call_1');
    expect(progress.tool, 'web_search');
    expect(progress.label, 'Searching');
    expect(progress.status, 'running');
  });

  test('unknown, unnamed, and progress error events remain strict', () async {
    for (final frame in [
      'data: {"status":"working"}\n\n',
      'event: unknown\ndata: {"status":"working"}\n\n',
      'event: hermes.tool.progress\ndata: {"error":{"message":"failed"}}\n\n',
    ]) {
      await expectLater(
        _StreamFixture('$frame$completion').start(_request),
        emitsError(isA<OllamaStreamException>()),
      );
    }
  });

  test('stream termination without DONE remains an error', () async {
    await expectLater(
      _StreamFixture(completion.replaceAll('data: [DONE]\n\n', ''))
          .start(_request),
      emitsInOrder([
        isA<OllamaChatChunk>(),
        emitsError(isA<OllamaStreamException>()),
      ]),
    );
  });

  test('auth and model failures retain status and provider detail', () async {
    for (final failure in [
      (status: 401, body: '{"error":{"message":"invalid api key"}}'),
      (status: 404, body: '{"error":{"message":"model not found"}}'),
    ]) {
      await expectLater(
        _StreamFixture(
          failure.body,
          statusCode: failure.status,
        ).start(_request),
        emitsError(
          isA<OllamaHttpException>()
              .having((error) => error.statusCode, 'statusCode', failure.status)
              .having((error) => error.body, 'body', failure.body),
        ),
      );
    }
  });

  test('cancellation closes the current compatible request', () async {
    final hanging = _HangingClient();
    final client = OpenAiCompatibleClient(
      baseUrl: 'https://example.test/v1',
      apiKey: '',
      client: MockClient((_) async => http.Response('{}', 200)),
      streamingClientFactory: () => hanging,
    );
    final chat = client.startChat(_request);
    final subscription = chat.stream.listen((_) {}, onError: (_) {});
    await hanging.sent.future;

    await chat.cancel();
    await subscription.cancel();

    expect(chat.isCancelled, isTrue);
    expect(hanging.closed, isTrue);
  });
}

const _request = OllamaChatRequest(
  model: 'test',
  messages: [OllamaChatMessage(role: OllamaRole.user, content: 'Hello')],
);

final class _StreamFixture {
  _StreamFixture(String frames, {this.statusCode = 200})
    : chunks = [utf8.encode(frames)] {
    _initialize();
  }

  _StreamFixture.fromChunks(this.chunks) : statusCode = 200 {
    _initialize();
  }

  void _initialize() {
    client = OpenAiCompatibleClient(
      baseUrl: 'https://example.test/v1',
      apiKey: 'test-key',
      client: MockClient((_) async => http.Response('{}', 200)),
      streamingClientFactory: () => MockClient.streaming((request, body) async {
        this.request = request;
        this.body = await body.bytesToString();
        return http.StreamedResponse(Stream.fromIterable(chunks), statusCode);
      }),
    );
  }

  final List<List<int>> chunks;
  final int statusCode;
  late final OpenAiCompatibleClient client;
  http.BaseRequest? request;
  String? body;

  Stream<OllamaChatChunk> start(OllamaChatRequest request) =>
      client.startChat(request).stream;
}

final class _HangingClient extends http.BaseClient {
  final sent = Completer<void>();
  final _controller = StreamController<List<int>>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!sent.isCompleted) sent.complete();
    return http.StreamedResponse(_controller.stream, 200, request: request);
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    _controller.close();
  }
}
