import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/ollama/ollama_client.dart';

void main() {
  test('message JSON round-trip preserves tool call ids and result ids', () {
    const assistant = OllamaChatMessage(
      role: OllamaRole.assistant,
      content: '',
      toolCalls: [
        OllamaToolCall(
          index: 0,
          id: 'call_1',
          name: 'web_search',
          arguments: {'query': 'llamas'},
        ),
      ],
    );
    const result = OllamaChatMessage(
      role: OllamaRole.tool,
      content: '{}',
      toolName: 'web_search',
      toolCallId: 'call_1',
    );

    final restoredAssistant = OllamaChatMessage.fromJson(assistant.toJson());
    final restoredResult = OllamaChatMessage.fromJson(result.toJson());

    expect(restoredAssistant.toolCalls.single.id, 'call_1');
    expect(restoredAssistant.toolCalls.single.index, 0);
    expect(restoredResult.toolCallId, 'call_1');
  });

  test(
    'normalizes routes and fetches show only when explicitly selected',
    () async {
      final requests = <http.Request>[];
      final shared = MockClient((request) async {
        requests.add(request);
        return switch (request.url.path) {
          '/proxy/api/version' => http.Response('{"version":"0.12.6"}', 200),
          '/proxy/api/tags' => http.Response(
            '{"models":['
            '{"name":"a","model":"a","modified_at":"",'
            '"size":1,"digest":"one","details":{}},'
            '{"name":"b","model":"b","modified_at":"",'
            '"size":2,"digest":"two","details":{}}]}',
            200,
          ),
          '/proxy/api/show' => http.Response(
            '{"capabilities":["vision","tools"],"details":{}}',
            200,
          ),
          _ => http.Response('not found', 404),
        };
      });
      final client = OllamaClient(
        baseUrl: ' https://example.test/proxy/// ',
        client: shared,
      );

      expect((await client.getVersion()).version, '0.12.6');
      expect(await client.listModels(), hasLength(2));
      final selected = await client.showModel('b');

      expect(selected.supportsVision, isTrue);
      expect(selected.supportsTools, isTrue);
      expect(requests.map((request) => request.url.path), [
        '/proxy/api/version',
        '/proxy/api/tags',
        '/proxy/api/show',
      ]);
      expect(jsonDecode(requests.last.body), {'model': 'b'});
    },
  );

  test('streams separate content, thinking, tool calls, and images', () async {
    final payload = utf8.encode(
      '{"model":"qwen","message":{"role":"assistant",'
      '"thinking":"plan ","content":"hé"},"done":false}\n'
      '{"model":"qwen","message":{"role":"assistant",'
      '"content":"llo","tool_calls":[{"function":{"index":0,'
      '"name":"web_search","arguments":{"query":"ollama"}}}]},'
      '"done":true,"done_reason":"stop"}\n',
    );
    final streamClient = _RecordingClient([
      payload.sublist(0, 17),
      payload.sublist(17, 63),
      payload.sublist(63, payload.length - 3),
      payload.sublist(payload.length - 3),
    ]);
    final shared = _RecordingClient(const []);
    final client = OllamaClient(
      baseUrl: 'http://localhost:11434',
      client: shared,
      streamingClientFactory: () => streamClient,
    );
    final chat = client.startChat(
      const OllamaChatRequest(
        model: 'qwen',
        messages: [
          OllamaChatMessage(
            role: OllamaRole.user,
            content: 'describe',
            images: ['aGVsbG8='],
          ),
        ],
        think: true,
      ),
    );

    final chunks = await chat.stream.toList();

    expect(chunks.map((chunk) => chunk.message.content).join(), 'héllo');
    expect(chunks.map((chunk) => chunk.message.thinking).join(), 'plan ');
    expect(chunks.last.message.toolCalls.single.name, 'web_search');
    expect(chunks.last.message.toolCalls.single.arguments['query'], 'ollama');
    expect(chunks.last.doneReason, 'stop');
    expect(streamClient.closed, isTrue);
    expect(shared.closed, isFalse);

    final request = jsonDecode(streamClient.request!.body) as Map;
    expect(request['stream'], isTrue);
    expect((request['messages'] as List).single['images'], ['aGVsbG8=']);
  });

  test(
    'cancellation closes only the request-scoped streaming client',
    () async {
      final shared = _RecordingClient(const []);
      final streaming = _HangingClient();
      final client = OllamaClient(
        baseUrl: 'http://localhost:11434',
        client: shared,
        streamingClientFactory: () => streaming,
      );
      final chat = client.startChat(
        const OllamaChatRequest(
          model: 'qwen',
          messages: [OllamaChatMessage(role: OllamaRole.user, content: 'hi')],
        ),
      );
      final subscription = chat.stream.listen((_) {}, onError: (_) {});
      await streaming.sent.future;

      await chat.cancel();
      await subscription.cancel();

      expect(chat.isCancelled, isTrue);
      expect(streaming.closed, isTrue);
      expect(shared.closed, isFalse);
    },
  );

  test('exposes status and raw body for HTTP stream failures', () async {
    final streamClient = _RecordingClient([
      utf8.encode('{"error":"model unavailable"}'),
    ], statusCode: 503);
    final client = OllamaClient(
      baseUrl: 'http://localhost:11434',
      client: _RecordingClient(const []),
      streamingClientFactory: () => streamClient,
    );

    await expectLater(
      client
          .startChat(
            const OllamaChatRequest(
              model: 'missing',
              messages: [
                OllamaChatMessage(role: OllamaRole.user, content: 'hi'),
              ],
            ),
          )
          .stream
          .toList(),
      throwsA(
        isA<OllamaHttpException>()
            .having((error) => error.statusCode, 'statusCode', 503)
            .having(
              (error) => error.body,
              'body',
              '{"error":"model unavailable"}',
            ),
      ),
    );
  });

  test('pulls a model through fragmented progress and exact success', () async {
    final payload = utf8.encode(
      '{"status":"pulling manifest"}\n'
      '{"status":"pulling sha256:abc","digest":"sha256:abc",'
      '"total":10,"completed":4}\n'
      '{"status":"success"}\n',
    );
    final streamClient = _RecordingClient([
      payload.sublist(0, 9),
      payload.sublist(9, 47),
      payload.sublist(47, payload.length - 2),
      payload.sublist(payload.length - 2),
    ]);
    final shared = _RecordingClient(const []);
    final client = OllamaClient(
      baseUrl: 'http://localhost:11434/proxy',
      client: shared,
      streamingClientFactory: () => streamClient,
    );

    final progress = await client
        .startModelPull('  gemma3:4b  ')
        .stream
        .toList();

    expect(progress.map((event) => event.status), [
      'pulling manifest',
      'pulling sha256:abc',
      'success',
    ]);
    expect(progress[1].digest, 'sha256:abc');
    expect(progress[1].total, 10);
    expect(progress[1].completed, 4);
    expect(progress[1].fraction, .4);
    expect(progress.last.isSuccess, isTrue);
    expect(streamClient.request!.method, 'POST');
    expect(streamClient.request!.url.path, '/proxy/api/pull');
    expect(jsonDecode(streamClient.request!.body), {
      'model': 'gemma3:4b',
      'stream': true,
    });
    expect(streamClient.closed, isTrue);
    expect(shared.closed, isFalse);
  });

  test('reports an Ollama model pull error record', () async {
    final streamClient = _RecordingClient([
      utf8.encode('{"error":"manifest not found"}\n'),
    ]);
    final client = OllamaClient(
      baseUrl: 'http://localhost:11434',
      client: _RecordingClient(const []),
      streamingClientFactory: () => streamClient,
    );

    await expectLater(
      client.startModelPull('missing').stream.toList(),
      throwsA(
        isA<OllamaStreamException>().having(
          (error) => error.message,
          'message',
          'manifest not found',
        ),
      ),
    );
    expect(streamClient.closed, isTrue);
  });

  test('rejects model pull EOF without success', () async {
    final streamClient = _RecordingClient([
      utf8.encode('{"status":"verifying sha256 digest"}\n'),
    ]);
    final client = OllamaClient(
      baseUrl: 'http://localhost:11434',
      client: _RecordingClient(const []),
      streamingClientFactory: () => streamClient,
    );

    await expectLater(
      client.startModelPull('gemma3').stream.toList(),
      throwsA(
        isA<OllamaStreamException>().having(
          (error) => error.message,
          'message',
          'Ollama model pull ended before success',
        ),
      ),
    );
  });

  test('model pull cancellation closes only its request client', () async {
    final shared = _RecordingClient(const []);
    final streaming = _HangingClient();
    final client = OllamaClient(
      baseUrl: 'http://localhost:11434',
      client: shared,
      streamingClientFactory: () => streaming,
    );
    final pull = client.startModelPull('gemma3');
    final progressSeen = Completer<void>();
    final completion = pull.stream.map((progress) {
      if (!progressSeen.isCompleted) progressSeen.complete();
      return progress;
    }).toList();
    final cancelled = expectLater(
      completion,
      throwsA(isA<OllamaCancelledException>()),
    );
    await streaming.sent.future;
    streaming.add(utf8.encode('{"status":"pulling manifest"}\n'));
    await progressSeen.future;

    await pull.cancel();
    await cancelled;

    expect(pull.isCancelled, isTrue);
    expect(streaming.closed, isTrue);
    expect(shared.closed, isFalse);
  });

  test('deletes a model with a bounded empty success response', () async {
    final shared = _RecordingClient(const []);
    final client = OllamaClient(
      baseUrl: 'http://localhost:11434/proxy',
      client: shared,
    );

    await client.deleteModel('  gemma3:4b  ');

    expect(shared.request!.method, 'DELETE');
    expect(shared.request!.url.path, '/proxy/api/delete');
    expect(jsonDecode(shared.request!.body), {'model': 'gemma3:4b'});
  });
}

class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.chunks, {this.statusCode = 200});

  final List<List<int>> chunks;
  final int statusCode;
  http.Request? request;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request as http.Request;
    return http.StreamedResponse(
      Stream.fromIterable(chunks),
      statusCode,
      request: request,
    );
  }

  @override
  void close() {
    closed = true;
  }
}

class _HangingClient extends http.BaseClient {
  final sent = Completer<void>();
  final _controller = StreamController<List<int>>();
  bool closed = false;

  void add(List<int> bytes) => _controller.add(bytes);

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
