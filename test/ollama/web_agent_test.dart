import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../lib/ollama/ollama_client.dart';
import '../../lib/ollama/openai_compatible_client.dart';
import '../../lib/ollama/web_agent.dart';

void main() {
  test('compatible transport runs whitelisted tools with matching call ids', () async {
    final first = _ChatClient(
      utf8.encode(
        'event: hermes.tool.progress\n'
                'data: {"tool":"server_search","label":"Searching","status":"running"}\n\n' +
            _openAiFrame({
              'tool_calls': [
                {
                  'index': 0,
                  'id': 'call_search',
                  'type': 'function',
                  'function': {
                    'name': 'web_search',
                    'arguments': '{"query":"Ollama"}',
                  },
                },
                {
                  'index': 1,
                  'id': 'call_shell',
                  'type': 'function',
                  'function': {'name': 'shell', 'arguments': '{}'},
                },
              ],
            }, null) +
            _openAiFrame({}, 'tool_calls') +
            'data: [DONE]\n\n',
      ),
    );
    final second = _ChatClient(
      utf8.encode(
        _openAiFrame({'content': 'Current answer'}, null) +
            _openAiFrame({}, 'stop') +
            'data: [DONE]\n\n',
      ),
    );
    final clients = Queue<_ChatClient>.of([first, second]);
    final compatible = OpenAiCompatibleClient(
      baseUrl: 'https://example.test/v1',
      apiKey: '',
      client: MockClient((_) async => http.Response('{}', 200)),
      streamingClientFactory: () => clients.removeFirst(),
    );
    var webCalls = 0;
    final agent = WebAgent.withChatStarter(
      startChat: compatible.startChat,
      webClientFactory: () => MockClient((_) async {
        webCalls++;
        return http.Response('{"results":[]}', 200);
      }),
      apiKey: 'web-key',
    );

    final events = await agent
        .run(
          model: 'test',
          messages: const [
            OllamaChatMessage(role: OllamaRole.user, content: 'Search'),
          ],
        )
        .stream
        .toList();

    expect(webCalls, 1);
    expect(
      events.whereType<WebAgentProviderToolProgress>().single.progress.label,
      'Searching',
    );
    expect(
      events
          .whereType<WebAgentToolActivity>()
          .where((event) => event.state == WebToolActivityState.failed)
          .single
          .call
          .name,
      'shell',
    );
    expect(
      events.whereType<WebAgentCompleted>().single.answer,
      'Current answer',
    );
    final firstRequest = jsonDecode(first.request!.body) as Map;
    expect(first.request!.headers['Authorization'], isNull);
    expect(
      (firstRequest['tools'] as List).map((tool) => tool['function']['name']),
      ['web_search', 'web_fetch'],
    );
    final secondRequest = jsonDecode(second.request!.body) as Map;
    final messages = secondRequest['messages'] as List;
    final assistant = messages[messages.length - 3] as Map;
    final searchResult = messages[messages.length - 2] as Map;
    final shellResult = messages.last as Map;
    expect((assistant['tool_calls'] as List).map((call) => call['id']), [
      'call_search',
      'call_shell',
    ]);
    expect(searchResult['tool_call_id'], 'call_search');
    expect(shellResult['tool_call_id'], 'call_shell');
    expect(
      jsonDecode(shellResult['content'])['error'],
      'Unsupported tool name',
    );
  });

  test(
    'runs bounded authenticated web search and returns a typed transcript',
    () async {
      final first = _ChatClient(
        _chunk(
          done: true,
          toolCalls: [
            {
              'function': {
                'name': 'web_search',
                'arguments': {'query': 'Ollama news', 'max_results': 10},
              },
            },
          ],
        ),
      );
      final second = _ChatClient(_chunk(content: 'Current answer', done: true));
      final chatClients = Queue<_ChatClient>.of([first, second]);
      http.Request? webRequest;
      final webClient = MockClient((request) async {
        webRequest = request;
        return http.Response(
          '{"results":['
          '{"title":"One","url":"https://one.test","content":"first"},'
          '{"title":"Two","url":"https://two.test","content":"second"}]}',
          200,
        );
      });
      final agent = WebAgent(
        ollama: OllamaClient(
          baseUrl: 'http://localhost:11434',
          client: MockClient((_) async => http.Response('{}', 200)),
          streamingClientFactory: () => chatClients.removeFirst(),
        ),
        webClientFactory: () => webClient,
        apiKey: 'secret',
        maxSearchResults: 1,
      );

      final events = await agent
          .run(
            model: 'qwen',
            messages: const [
              OllamaChatMessage(
                role: OllamaRole.user,
                content: 'What changed?',
              ),
            ],
          )
          .stream
          .toList();

      expect(webRequest!.url.toString(), 'https://ollama.com/api/web_search');
      expect(webRequest!.headers['Authorization'], 'Bearer secret');
      expect(jsonDecode(webRequest!.body)['max_results'], 1);
      expect(
        events.whereType<WebAgentToolActivity>().map((event) => event.state),
        [WebToolActivityState.running, WebToolActivityState.completed],
      );
      expect(
        events.whereType<WebAgentCompleted>().single.answer,
        'Current answer',
      );

      final secondRequest = jsonDecode(second.request!.body) as Map;
      final toolMessage = (secondRequest['messages'] as List).last as Map;
      expect(toolMessage['role'], 'tool');
      expect(toolMessage['tool_name'], 'web_search');
      expect(
        (jsonDecode(toolMessage['content'])['results'] as List),
        hasLength(1),
      );
    },
  );

  test(
    'rejects unknown tools and invalid arguments without a web request',
    () async {
      final first = _ChatClient(
        _chunk(
          done: true,
          toolCalls: [
            {
              'function': {'name': 'shell', 'arguments': <String, dynamic>{}},
            },
            {
              'function': {
                'name': 'web_fetch',
                'arguments': {'url': 'file:///etc/passwd'},
              },
            },
          ],
        ),
      );
      final second = _ChatClient(_chunk(content: 'Recovered', done: true));
      final clients = Queue<_ChatClient>.of([first, second]);
      var webCalls = 0;
      final agent = WebAgent(
        ollama: OllamaClient(
          baseUrl: 'http://localhost:11434',
          client: MockClient((_) async => http.Response('{}', 200)),
          streamingClientFactory: () => clients.removeFirst(),
        ),
        webClientFactory: () => MockClient((_) async {
          webCalls++;
          return http.Response('{}', 200);
        }),
        apiKey: 'secret',
      );

      final events = await agent
          .run(
            model: 'qwen',
            messages: const [
              OllamaChatMessage(role: OllamaRole.user, content: 'go'),
            ],
          )
          .stream
          .toList();

      expect(webCalls, 0);
      expect(
        events.whereType<WebAgentToolActivity>().where(
          (event) => event.state == WebToolActivityState.failed,
        ),
        hasLength(2),
      );
      expect(events.whereType<WebAgentCompleted>().single.answer, 'Recovered');
    },
  );

  test('stops before a ninth model turn', () async {
    final clients = Queue<_ChatClient>.of(
      List.generate(
        8,
        (_) => _ChatClient(
          _chunk(
            done: true,
            toolCalls: [
              {
                'function': {
                  'name': 'unknown',
                  'arguments': <String, dynamic>{},
                },
              },
            ],
          ),
        ),
      ),
    );
    final agent = WebAgent(
      ollama: OllamaClient(
        baseUrl: 'http://localhost:11434',
        client: MockClient((_) async => http.Response('{}', 200)),
        streamingClientFactory: () => clients.removeFirst(),
      ),
      webClientFactory: () => MockClient((_) async => http.Response('{}', 200)),
      apiKey: 'secret',
    );

    final events = await agent
        .run(
          model: 'qwen',
          messages: const [
            OllamaChatMessage(role: OllamaRole.user, content: 'go'),
          ],
        )
        .stream
        .toList();

    expect(events.whereType<WebAgentTurnStarted>(), hasLength(8));
    expect(
      events.whereType<WebAgentFailed>().single.error,
      isA<WebAgentLimitException>(),
    );
    expect(clients, isEmpty);
  });
}

String _openAiFrame(Map<String, dynamic> delta, String? finishReason) =>
    'data: ${jsonEncode({
      'model': 'test',
      'choices': [
        {'index': 0, 'delta': delta, 'finish_reason': finishReason},
      ],
    })}\n\n';

List<int> _chunk({
  String content = '',
  bool done = false,
  List<Map<String, dynamic>> toolCalls = const [],
}) {
  return utf8.encode(
    '${jsonEncode({
      'model': 'qwen',
      'message': {'role': 'assistant', 'content': content, if (toolCalls.isNotEmpty) 'tool_calls': toolCalls},
      'done': done,
    })}\n',
  );
}

class _ChatClient extends http.BaseClient {
  _ChatClient(this.bytes);

  final List<int> bytes;
  http.Request? request;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request as http.Request;
    return http.StreamedResponse(Stream.value(bytes), 200, request: request);
  }
}
