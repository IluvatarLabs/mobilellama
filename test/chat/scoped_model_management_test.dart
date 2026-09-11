import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/chat/chat_controller.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/ollama/ollama_client.dart';

import '../support/chat_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit Lab model management never changes the active Home chat',
    () async {
      final fixture = ChatFixture();
      await fixture.open();
      await fixture.seed('home-chat');
      await fixture.settings.upsertProfile(
        ServerProfile(
          id: 'compatible',
          name: 'Compatible',
          protocol: ServerProtocol.openAiCompatible,
          baseUrl: 'https://compatible.test/v1',
        ),
      );
      await fixture.controller.shutdown();
      fixture.controller.dispose();

      final home = _ScopedOllamaServer(
        host: 'home.test',
        installed: <String>['qwen3:4b'],
      );
      final lab = _ScopedOllamaServer(
        host: 'lab.test',
        installed: <String>['lab-old:latest'],
      );
      final servers = <String, _ScopedOllamaServer>{
        home.host: home,
        lab.host: lab,
      };
      fixture.controller = ChatController(
        conversations: fixture.store,
        settings: fixture.settings,
        secrets: fixture.secrets,
        images: fixture.images,
        ollamaClientFactory: (url) {
          final server = servers[Uri.parse(url).host]!;
          return OllamaClient(
            baseUrl: url,
            client: server.unaryClient,
            streamingClientFactory: server.createPullClient,
          );
        },
        webAgentFactory: ({required ollama, required apiKey}) =>
            throw UnimplementedError('Web Agent is outside this test'),
        idFactory: () => 'unused',
      );
      addTearDown(fixture.close);
      await fixture.controller.initialize();
      await fixture.controller.openConversation('home-chat');
      fixture.controller.setDraftText('Keep the Home draft');
      await fixture.controller.flushDrafts();
      final originalModel = fixture.controller.selectedModel;
      home.requests.clear();
      lab.requests.clear();

      final listed = await fixture.controller.loadModelsForProfile('lab');
      expect(listed.map((model) => model.name), <String>['lab-old:latest']);
      expect(
        fixture.controller.modelsForProfile('lab').map((model) => model.name),
        <String>['lab-old:latest'],
      );
      expect(
        fixture.controller
            .detailsForModel('lab-old:latest', profileId: 'lab')
            ?.supportsTools,
        isTrue,
      );

      expect(
        await fixture.controller.pullModel('lab-new:latest', profileId: 'lab'),
        isTrue,
      );
      expect(
        fixture.controller.modelsForProfile('lab').map((model) => model.name),
        contains('lab-new:latest'),
      );
      expect(
        fixture.controller.modelManagementStatusForProfile('lab'),
        'Downloaded lab-new:latest.',
      );
      expect(
        fixture.controller.modelManagementStatusForProfile('home'),
        isNull,
      );

      expect(
        await fixture.controller.deleteModel(
          'lab-old:latest',
          profileId: 'lab',
        ),
        isTrue,
      );
      expect(
        fixture.controller.modelsForProfile('lab').map((model) => model.name),
        <String>['lab-new:latest'],
      );
      expect(lab.deleted, <String>['lab-old:latest']);
      expect(lab.pulled, <String>['lab-new:latest']);
      expect(lab.requests, containsAll(<String>['/api/show', '/api/delete']));
      expect(home.requests, isEmpty);

      expect(
        fixture.controller.canManageModelsForProfile('compatible'),
        isFalse,
      );
      expect(
        await fixture.controller.deleteModel(
          'anything',
          profileId: 'compatible',
        ),
        isFalse,
      );
      expect(fixture.controller.activeProfileId, 'home');
      expect(fixture.controller.conversation?.id, 'home-chat');
      expect(fixture.controller.selectedModel, originalModel);
      expect(fixture.controller.draftText, 'Keep the Home draft');
      expect(fixture.controller.canSend, isTrue);

      // A model can also disappear through another client on the server.
      home.installed.clear();
      await fixture.controller.loadModelsForProfile('home');
      expect(fixture.controller.selectedModel, isNull);
      expect(fixture.controller.conversation?.selectedModel, originalModel);
      expect(fixture.controller.draftText, 'Keep the Home draft');
      expect(fixture.controller.canSend, isFalse);
      home.installed.add('qwen3:4b');
      await fixture.controller.loadModelsForProfile('home');
      expect(await fixture.controller.selectModel('qwen3:4b'), isTrue);
      expect(fixture.controller.canSend, isTrue);

      expect(
        await fixture.controller.deleteModel('qwen3:4b', profileId: 'home'),
        isTrue,
      );
      expect(fixture.controller.selectedModel, isNull);
      expect(fixture.controller.conversation?.selectedModel, originalModel);
      expect(fixture.controller.draftText, 'Keep the Home draft');
      expect(fixture.controller.canSend, isFalse);
    },
  );
}

final class _ScopedOllamaServer {
  _ScopedOllamaServer({required this.host, required List<String> installed})
    : installed = List<String>.of(installed) {
    unaryClient = MockClient(_handleUnary);
  }

  final String host;
  final List<String> installed;
  late final MockClient unaryClient;
  final List<String> requests = <String>[];
  final List<String> pulled = <String>[];
  final List<String> deleted = <String>[];

  Future<http.Response> _handleUnary(http.Request request) async {
    requests.add(request.url.path);
    return switch (request.url.path) {
      '/api/version' => http.Response('{"version":"0.12.6"}', 200),
      '/api/tags' => http.Response(
        jsonEncode({
          'models': [
            for (final model in installed)
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
        '{"details":{},"capabilities":["thinking","tools"]}',
        200,
      ),
      '/api/delete' => _delete(request),
      _ => http.Response('not found', 404),
    };
  }

  http.Response _delete(http.Request request) {
    final model =
        (jsonDecode(request.body) as Map<String, dynamic>)['model'] as String;
    deleted.add(model);
    installed.remove(model);
    return http.Response('', 200);
  }

  http.Client createPullClient() => _CompletingPullClient((model) {
    requests.add('/api/pull');
    pulled.add(model);
    if (!installed.contains(model)) installed.add(model);
  });
}

final class _CompletingPullClient extends http.BaseClient {
  _CompletingPullClient(this.onPull);

  final void Function(String model) onPull;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = jsonDecode(
      await request.finalize().bytesToString(),
    ) as Map<String, dynamic>;
    onPull(body['model'] as String);
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[
        utf8.encode('{"status":"pulling manifest"}\n'),
        utf8.encode('{"status":"success"}\n'),
      ]),
      200,
      request: request,
    );
  }
}
