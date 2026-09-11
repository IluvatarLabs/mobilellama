import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/chat/chat_controller.dart';
import 'package:mobollama/chat/model_management_page.dart';
import 'package:mobollama/ollama/ollama_client.dart';

import '../support/chat_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('controller cancellation releases the model operation', () async {
    final harness = await _ModelManagementHarness.open();
    addTearDown(harness.close);
    final progressReceived = Completer<void>();
    void observeProgress() {
      if (harness.controller.modelManagementStatus == 'pulling manifest' &&
          !progressReceived.isCompleted) {
        progressReceived.complete();
      }
    }

    harness.controller.addListener(observeProgress);
    addTearDown(() => harness.controller.removeListener(observeProgress));
    final operation = harness.controller.pullModel('gemma3:4b');
    final pullClient = await harness.server.pullClientCreated.future.timeout(
      const Duration(seconds: 5),
    );
    await pullClient.sent.future;
    await progressReceived.future.timeout(const Duration(seconds: 5));
    await harness.controller.cancelModelPull().timeout(
      const Duration(seconds: 5),
    );
    expect(await operation, isFalse);
    expect(harness.controller.modelManagementBusy, isFalse);
    expect(harness.controller.modelManagementStatus, 'Download cancelled.');
  });

  testWidgets(
    'model page shows server context and wires download cancellation',
    (tester) async {
      final harness = (await tester.runAsync(
        () => _ModelManagementHarness.open(pageController: true),
      ))!;
      addTearDown(harness.close);
      final controller = harness.controller as _ModelPageController;
      await tester.pumpWidget(
        MaterialApp(
          home: ModelManagementPage(controller: controller, profileId: 'lab'),
        ),
      );

      expect(find.text('Models are stored on Lab, not this phone.'), findsOne);
      expect(find.text('qwen3:4b'), findsOne);
      await tester.enterText(find.byType(TextField), '  gemma3:4b  ');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Download'));
      await tester.pump();

      expect(controller.requestedPulls, <(String, String)>[
        ('lab', 'gemma3:4b'),
      ]);
      expect(find.text('pulling manifest'), findsOne);
      expect(find.widgetWithText(TextButton, 'Cancel'), findsOne);
      expect(
        tester.getSize(find.widgetWithText(TextButton, 'Cancel')).height,
        greaterThanOrEqualTo(44),
      );

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pump();
      expect(controller.cancelledProfiles, <String>['lab']);
      expect(find.text('Download cancelled.'), findsOne);
    },
  );

  testWidgets('delete confirms exact server and rechecks the live busy guard', (
    tester,
  ) async {
    final harness = (await tester.runAsync(
      () => _ModelManagementHarness.open(pageController: true),
    ))!;
    addTearDown(harness.close);
    final controller = harness.controller as _ModelPageController;
    await tester.pumpWidget(
      MaterialApp(
        home: ModelManagementPage(controller: controller, profileId: 'lab'),
      ),
    );
    await tester.pumpAndSettle();

    final deleteButton = find.byTooltip('Delete qwen3:4b');
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    expect(find.text('Delete qwen3:4b?'), findsOne);
    expect(find.textContaining('Delete qwen3:4b from Lab?'), findsOne);

    controller.beginBusyPull('another:latest', profileId: 'lab');
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pump();
    expect(controller.deletedModels, isEmpty);
    expect(find.text('Wait for the current action to finish.'), findsOne);

    await controller.cancelModelPull(profileId: 'lab');
    await tester.pumpAndSettle();
    await tester.ensureVisible(deleteButton);
    await tester.tap(deleteButton);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(controller.deletedModels, <(String, String)>[('lab', 'qwen3:4b')]);
    expect(find.text('qwen3:4b'), findsNothing);
    expect(find.text('Deleted qwen3:4b.'), findsOne);
  });
}

final class _ModelManagementHarness {
  _ModelManagementHarness._(this.fixture, this.controller, this.server);

  final ChatFixture fixture;
  final ChatController controller;
  final _ModelServer server;

  static Future<_ModelManagementHarness> open({
    bool pageController = false,
  }) async {
    final fixture = ChatFixture();
    await fixture.open();
    await fixture.controller.shutdown();
    fixture.controller.dispose();
    final server = _ModelServer();
    final controller = pageController
        ? _ModelPageController(fixture, server)
        : ChatController(
            conversations: fixture.store,
            settings: fixture.settings,
            secrets: fixture.secrets,
            images: fixture.images,
            ollamaClientFactory: (url) => OllamaClient(
              baseUrl: url,
              client: server.unaryClient,
              streamingClientFactory: server.createPullClient,
            ),
            webAgentFactory: ({required ollama, required apiKey}) =>
                throw UnimplementedError('Web Agent is outside this test'),
            idFactory: () => 'unused',
          );
    fixture.controller = controller;
    await controller.initialize();
    return _ModelManagementHarness._(fixture, controller, server);
  }

  Future<void> close() => fixture.close();
}

final class _ModelPageController extends ChatController {
  _ModelPageController(ChatFixture fixture, _ModelServer server)
    : super(
        conversations: fixture.store,
        settings: fixture.settings,
        secrets: fixture.secrets,
        images: fixture.images,
        ollamaClientFactory: (url) => OllamaClient(
          baseUrl: url,
          client: server.unaryClient,
          streamingClientFactory: server.createPullClient,
        ),
        webAgentFactory: ({required ollama, required apiKey}) =>
            throw UnimplementedError('Web Agent is outside this test'),
        idFactory: () => 'unused',
      );

  final List<(String, String)> requestedPulls = <(String, String)>[];
  final List<(String, String)> deletedModels = <(String, String)>[];
  final List<ChatModelOption> _pageModels = <ChatModelOption>[
    const ChatModelOption('qwen3:4b'),
  ];
  bool _busy = false;
  bool _pullActive = false;
  String? _status;
  String? _operationProfileId;
  final List<String> cancelledProfiles = <String>[];

  @override
  List<ChatModelOption> modelsForProfile(String profileId) =>
      List.unmodifiable(_pageModels);

  @override
  bool canManageModelsForProfile(String profileId) => true;

  @override
  bool modelManagementBusyForProfile(String profileId) =>
      _operationProfileId == profileId && _busy;

  @override
  bool modelPullActiveForProfile(String profileId) =>
      _operationProfileId == profileId && _pullActive;

  @override
  String? modelManagementStatusForProfile(String profileId) =>
      _operationProfileId == profileId ? _status : null;

  @override
  String? modelManagementErrorForProfile(String profileId) => null;

  @override
  double? modelDownloadProgressForProfile(String profileId) => null;

  @override
  Future<List<ChatModelOption>> loadModelsForProfile(String profileId) async =>
      List.unmodifiable(_pageModels);

  @override
  Future<void> loadModelCapabilities({String? profileId}) async {}

  @override
  Future<bool> pullModel(String name, {String? profileId}) async {
    beginBusyPull(name, profileId: profileId!);
    return false;
  }

  void beginBusyPull(String name, {required String profileId}) {
    requestedPulls.add((profileId, name.trim()));
    _operationProfileId = profileId;
    _busy = true;
    _pullActive = true;
    _status = 'pulling manifest';
    notifyListeners();
  }

  @override
  Future<void> cancelModelPull({String? profileId}) async {
    final operationProfileId = profileId ?? _operationProfileId;
    if (!_busy || operationProfileId == null) return;
    cancelledProfiles.add(operationProfileId);
    _busy = false;
    _pullActive = false;
    _status = 'Download cancelled.';
    notifyListeners();
  }

  @override
  Future<bool> deleteModel(String name, {String? profileId}) async {
    deletedModels.add((profileId!, name));
    _pageModels.removeWhere((model) => model.name == name);
    _status = 'Deleted $name.';
    notifyListeners();
    return true;
  }
}

final class _ModelServer {
  _ModelServer() {
    unaryClient = MockClient(_handleUnary);
  }

  late MockClient unaryClient;
  final installed = <String>['qwen3:4b'];
  final deleteRequests = <String>[];
  final pullClients = <_HangingPullClient>[];
  final pullClientCreated = Completer<_HangingPullClient>();

  Future<http.Response> _handleUnary(http.Request request) async {
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
                'size': 2 * 1024 * 1024,
                'digest': model,
                'details': {
                  'family': 'qwen3',
                  'parameter_size': '4B',
                  'quantization_level': 'Q4_K_M',
                },
              },
          ],
        }),
        200,
      ),
      '/api/show' => http.Response(
        jsonEncode({
          'details': {
            'family': 'qwen3',
            'parameter_size': '4B',
            'quantization_level': 'Q4_K_M',
          },
          'capabilities': ['thinking', 'tools'],
        }),
        200,
      ),
      '/api/delete' => _delete(request),
      _ => http.Response('not found', 404),
    };
  }

  http.Response _delete(http.Request request) {
    final model =
        (jsonDecode(request.body) as Map<String, dynamic>)['model'] as String;
    deleteRequests.add(model);
    installed.remove(model);
    return http.Response('', 200);
  }

  http.Client createPullClient() {
    final client = _HangingPullClient();
    pullClients.add(client);
    if (!pullClientCreated.isCompleted) pullClientCreated.complete(client);
    return client;
  }
}

final class _HangingPullClient extends http.BaseClient {
  final sent = Completer<void>();
  final _events = StreamController<List<int>>();
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!sent.isCompleted) sent.complete();
    _events.add(utf8.encode('{"status":"pulling manifest"}\n'));
    return http.StreamedResponse(_events.stream, 200, request: request);
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    unawaited(_events.close());
  }
}
