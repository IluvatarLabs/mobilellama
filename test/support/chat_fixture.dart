import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mobollama/chat/chat_controller.dart';
import 'package:mobollama/chat/background_execution.dart';
import 'package:mobollama/data/conversation_store.dart';
import 'package:mobollama/data/document_reader.dart';
import 'package:mobollama/data/chat_sync.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/data/sqflite_database.dart';
import 'package:mobollama/domain/conversation.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/ollama/ollama_client.dart';
import 'package:mobollama/ollama/openai_compatible_client.dart';

class ChatFixture {
  late Database database;
  late ConversationStore store;
  late SettingsStore settings;
  late ChatController controller;
  final preferences = TestPreferences();
  final images = TestImages();
  final secrets = TestSecrets();
  final failedHosts = <String>{};

  /// Holds unary requests to a host until the completer completes.
  final holds = <String, Completer<void>>{};
  final requests = <Map<String, dynamic>>[];
  final models = ['qwen3:4b', 'gemma3:4b'];
  bool holdResponse = false;
  int failNextResponses = 0;
  final List<TestResponseControl> responseControls = [];
  ChatBackgroundExecution? backgroundExecution;
  DocumentReader? documentReader;
  ChatSyncBridge? syncBridge;
  int _id = 0;

  Future<void> open({int version = ConversationStore.schemaVersion}) async {
    sqfliteFfiInit();
    database = await databaseFactoryFfiNoIsolate.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(singleInstance: false),
    );
    store = ConversationStore(SqfliteDatabaseAdapter(database));
    await store.migrate(
      fromVersion: 0,
      toVersion: version,
      legacyServerProfileId: 'home',
    );
    settings = SettingsStore(preferences);
    await settings.upsertProfile(
      ServerProfile(
        id: 'home',
        name: 'Home',
        protocol: ServerProtocol.ollama,
        baseUrl: 'https://home.test',
      ),
    );
    await settings.upsertProfile(
      ServerProfile(
        id: 'lab',
        name: 'Lab',
        protocol: ServerProtocol.ollama,
        baseUrl: 'https://lab.test',
      ),
    );
    await settings.setActiveProfile('home');
    createController();
  }

  void createController() {
    controller = ChatController(
      conversations: store,
      settings: settings,
      secrets: secrets,
      images: images,
      documentReader: documentReader,
      syncBridge: syncBridge,
      backgroundExecution: backgroundExecution,
      idFactory: () => 'created-${++_id}',
      ollamaClientFactory: (url) => OllamaClient(
        baseUrl: url,
        client: MockClient((request) async {
          await holds[request.url.host]?.future;
          if (failedHosts.contains(request.url.host)) {
            throw http.ClientException('Server unavailable');
          }
          return switch (request.url.path) {
            '/api/version' => http.Response('{"version":"0.12.6"}', 200),
            '/api/tags' => http.Response(
              jsonEncode({
                'models': [
                  for (final model in models)
                    {
                      'name': model,
                      'model': model,
                      'modified_at': '',
                      'size': 1,
                      'digest': model,
                      'details': {},
                    },
                ],
              }),
              200,
            ),
            '/api/show' => http.Response(
              jsonEncode({
                'details': {},
                'capabilities': jsonDecode(request.body)['model'] == 'gemma3:4b'
                    ? ['vision']
                    : ['thinking', 'tools'],
              }),
              200,
            ),
            _ => http.Response('not found', 404),
          };
        }),
        streamingClientFactory: () => _ResponseClient(this),
      ),
      webAgentFactory: ({required ollama, required apiKey}) =>
          throw UnimplementedError('Web Agent is outside this fixture'),
      openAiCompatibleClientFactory: (url, key) => OpenAiCompatibleClient(
        baseUrl: url,
        apiKey: key,
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'compatible-model',
                  'capabilities': ['vision', 'tools'],
                },
              ],
            }),
            200,
          ),
        ),
        streamingClientFactory: () => _CompatibleResponseClient(this),
      ),
    );
  }

  Future<Conversation> seed(
    String id, {
    String profile = 'home',
    String title = 'Saved conversation',
    String content = 'Previously saved answer',
    String model = 'qwen3:4b',
  }) async {
    await store.createConversation(
      id: id,
      serverProfileId: profile,
      selectedModel: model,
      systemPrompt: 'Be clear.',
    );
    await store.appendMessage(
      id: '$id-user',
      conversationId: id,
      role: MessageRole.user,
      status: MessageStatus.complete,
      content: title,
    );
    await store.appendMessage(
      id: '$id-assistant',
      conversationId: id,
      role: MessageRole.assistant,
      status: MessageStatus.complete,
      content: content,
    );
    return (await store.openConversation(
      serverProfileId: profile,
      id: id,
    ))!.conversation;
  }

  Future<void> close() async {
    await controller.shutdown();
    controller.dispose();
    await database.close();
  }
}

class _ResponseClient extends http.BaseClient {
  _ResponseClient(this.fixture);
  final ChatFixture fixture;
  final _events = StreamController<List<int>>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonDecode(
      await request.finalize().bytesToString(),
    ) as Map<String, dynamic>;
    fixture.requests.add({...body, 'host': request.url.host});
    if (fixture.failNextResponses > 0) {
      fixture.failNextResponses--;
      return http.StreamedResponse(
        Stream.value(utf8.encode('unavailable')),
        503,
      );
    }
    final control = TestResponseControl(_events, body['model'] as String);
    fixture.responseControls.add(control);
    _events.add(
      utf8.encode(
        '${jsonEncode({
          'model': body['model'],
          'message': {'role': 'assistant', 'content': 'A saved response.'},
          'done': false,
        })}\n',
      ),
    );
    if (!fixture.holdResponse) {
      control.complete();
    }
    return http.StreamedResponse(_events.stream, 200);
  }

  @override
  void close() {
    if (!_events.isClosed) unawaited(_events.close());
  }
}

class TestResponseControl {
  TestResponseControl(this.events, this.model);
  final StreamController<List<int>> events;
  final String model;

  void complete() {
    if (events.isClosed) return;
    events.add(
      utf8.encode(
        '${jsonEncode({
          'model': model,
          'message': {'role': 'assistant', 'content': ''},
          'done': true,
          'done_reason': 'stop',
        })}\n',
      ),
    );
    unawaited(events.close());
  }

  void fail() {
    if (events.isClosed) return;
    events.addError(http.ClientException('Network disconnected'));
    unawaited(events.close());
  }
}

class _CompatibleResponseClient extends http.BaseClient {
  _CompatibleResponseClient(this.fixture);
  final ChatFixture fixture;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonDecode(
      await request.finalize().bytesToString(),
    ) as Map<String, dynamic>;
    fixture.requests.add({...body, 'headers': request.headers});
    final frames = [
      'event: hermes.tool.progress\ndata: {"toolCallId":"remote-1","tool":"browser","label":"Read the page","status":"completed"}\n\n',
      'data: {"choices":[{"index":0,"delta":{"reasoning_content":"Considered the image."},"finish_reason":null}]}\n\n',
      'data: {"choices":[{"index":0,"delta":{"content":"An image answer."},"finish_reason":null}]}\n\n',
      'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n',
      'data: [DONE]\n\n',
    ];
    return http.StreamedResponse(
      Stream.fromIterable(frames.map(utf8.encode)),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}

class TestPreferences implements PreferencesDriver {
  final values = <String, Object>{};
  bool failWrites = false;
  @override
  String? getString(String key) => values[key] as String?;
  @override
  bool? getBool(String key) => values[key] as bool?;
  @override
  Future<void> setString(String key, String value) async {
    if (failWrites) throw StateError('injected preference write failure');
    values[key] = value;
  }

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }
}

class TestSecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class TestImages implements ImageAttachmentStore {
  final Map<String, List<int>> bytesByReference = {};
  int _copies = 0;
  final deleted = <String>[];
  @override
  Future<String> writeBytes({
    required String conversationId,
    required List<int> bytes,
    required String sourceName,
  }) async {
    final reference = 'image:$conversationId:${++_copies}:$sourceName';
    bytesByReference[reference] = List.of(bytes);
    return reference;
  }

  @override
  Future<String?> pickAndCopy({
    required String conversationId,
    bool camera = false,
  }) async => 'image:$conversationId:${++_copies}';
  @override
  Future<String> readAsBase64(String reference) async =>
      bytesByReference.containsKey(reference)
      ? base64Encode(bytesByReference[reference]!)
      : 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6XkAAAAASUVORK5CYII=';
  @override
  Future<int> sizeInBytes(String reference) async =>
      bytesByReference[reference]?.length ?? 68;
  @override
  Future<void> deleteReference(String reference) async {
    deleted.add(reference);
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    deleted.add(conversationId);
  }
}
