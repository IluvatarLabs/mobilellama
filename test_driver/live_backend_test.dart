// Opt-in live acceptance. Never part of the default fixture suite.
// MOBILELLAMA_LIVE_OLLAMA=http://host:11434 MOBILELLAMA_LIVE_MODEL=model \
//   flutter test test_driver/live_backend_test.dart --no-pub
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mobollama/chat/chat_controller.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/domain/message.dart';
import 'package:mobollama/ollama/ollama_client.dart';
import 'package:mobollama/ollama/openai_compatible_client.dart';
import 'package:mobollama/ollama/web_agent.dart';

import '../test/support/chat_fixture.dart';

void main() {
  final endpoint = Platform.environment['MOBILELLAMA_LIVE_OLLAMA'];
  final model = Platform.environment['MOBILELLAMA_LIVE_MODEL'];
  if (endpoint == null || model == null) {
    throw StateError('Set MOBILELLAMA_LIVE_OLLAMA and MOBILELLAMA_LIVE_MODEL.');
  }
  var sequence = 0;
  var webCalls = 0;
  Future<ChatFixture> connect(ServerProfile profile) async {
    final fixture = ChatFixture();
    await fixture.open();
    fixture.controller.dispose();
    final unary = http.Client();
    addTearDown(unary.close);
    await fixture.settings.upsertProfile(profile);
    await fixture.settings.setActiveProfile(profile.id);
    fixture.controller = ChatController(
      conversations: fixture.store,
      settings: fixture.settings,
      secrets: fixture.secrets,
      images: fixture.images,
      ollamaClientFactory: (url) => OllamaClient(baseUrl: url, client: unary),
      openAiCompatibleClientFactory: (url, key) =>
          OpenAiCompatibleClient(baseUrl: url, apiKey: key, client: unary),
      webAgentFactory: ({required ollama, required apiKey}) =>
          throw StateError('This check does not call external web tools.'),
      compatibleWebAgentFactory: ({required client, required apiKey}) =>
          WebAgent.withChatStarter(
            startChat: client.startChat,
            apiKey: apiKey,
            // Inference and tool-call replay are real; web content is a fixed
            // fixture so this check has no external search credential or cost.
            webClientFactory: () => MockClient((_) async {
              webCalls++;
              return http.Response(
                jsonEncode({
                  'results': [
                    {
                      'title': 'Archive code',
                      'url': 'https://example.test/archive',
                      'content': 'The current archive code is violet58.',
                    },
                  ],
                }),
                200,
              );
            }),
          ),
      idFactory: () => 'live-${++sequence}',
    );
    addTearDown(fixture.close);
    await fixture.controller.initialize();
    final result = await fixture.controller.saveAndConnectServerProfile(
      profile,
    );
    expect(result.connection?.succeeded, isTrue, reason: result.message);
    expect(await fixture.controller.selectModel(model), isTrue);
    return fixture;
  }

  for (final mode in ['ollama', 'chatCompletions', 'responses']) {
    test('live $mode: context, settled output, and stopped partial', () async {
      final profile = ServerProfile(
        id: mode,
        name: 'Live acceptance',
        protocol: mode == 'ollama'
            ? ServerProtocol.ollama
            : ServerProtocol.openAiCompatible,
        compatibleApi: mode == 'responses'
            ? CompatibleApi.responses
            : CompatibleApi.chatCompletions,
        baseUrl: mode == 'ollama' ? endpoint : '$endpoint/v1',
        acknowledgedInsecureOrigin: SettingsStore.endpointOrigin(endpoint),
      );
      final f = await connect(profile);
      expect(
        await f.controller.send(
          'Remember the code lavender42. Reply only with acknowledged.',
        ),
        isTrue,
      );
      expect(f.controller.messages.last.status, MessageStatus.complete);
      expect(f.controller.messages.last.content, isNotEmpty);
      expect(
        await f.controller.send(
          'What code did I ask you to remember? Reply only with the code.',
        ),
        isTrue,
      );
      expect(f.controller.messages.last.status, MessageStatus.complete);
      expect(
        f.controller.messages.last.content.toLowerCase(),
        contains('lavender42'),
      );

      if (mode == 'responses') {
        Future<void> enableTools(ChatController controller) async {
          await controller.setCompatibleCapability('tools', true);
          await controller.saveWebApiKey('fixture-only');
          await controller.acknowledgeWebDisclosure();
          expect(await controller.setWebAgentEnabled(true), isTrue);
        }

        await enableTools(f.controller);
        final beforeTools = webCalls;
        expect(
          await f.controller.send(
            'Use web_search to look up the current archive code. Report the code from the search result.',
          ),
          isTrue,
        );
        expect(f.controller.messages.last.status, MessageStatus.complete);
        expect(
          f.controller.messages.last.content.toLowerCase(),
          contains('violet58'),
        );
        expect(webCalls, greaterThan(beforeTools));
        final restored = await connect(profile);
        expect(
          await restored.controller.importBackup(
            await f.controller.exportBackup(),
          ),
          1,
        );
        await restored.controller.openConversation(
          restored.controller.history.single.id,
        );
        expect(
          await restored.controller.send(
            'Repeat the remembered code, with no other words.',
          ),
          isTrue,
        );
        expect(
          restored.controller.messages.last.status,
          MessageStatus.complete,
        );
        expect(
          restored.controller.messages.last.content.toLowerCase(),
          contains('lavender42'),
        );
        await enableTools(restored.controller);
        final beforeRestoredTools = webCalls;
        expect(
          await restored.controller.send(
            'Use web_search again to confirm the archive code is still current. Report the verified code.',
          ),
          isTrue,
        );
        expect(
          restored.controller.messages.last.status,
          MessageStatus.complete,
        );
        expect(
          restored.controller.messages.last.content.toLowerCase(),
          contains('violet58'),
        );
        expect(webCalls, greaterThan(beforeRestoredTools));
      }

      final partial = Completer<void>();
      final settledCount = f.controller.messages.length;
      void observe() {
        if (f.controller.messages.length > settledCount &&
            f.controller.messages.last.role == MessageRole.assistant &&
            f.controller.messages.last.content.isNotEmpty &&
            !partial.isCompleted) {
          partial.complete();
        }
      }

      f.controller.addListener(observe);
      final sending = f.controller.send(
        'Write a detailed 2000 word explanation of how rain forms.',
      );
      await partial.future.timeout(const Duration(seconds: 90));
      await f.controller.stop();
      await sending;
      f.controller.removeListener(observe);
      final answer = f.controller.messages.last;
      expect(answer.content, isNotEmpty);
      expect(answer.status, MessageStatus.interrupted);
      final saved = await f.store.openConversation(
        serverProfileId: mode,
        id: f.controller.conversation!.id,
      );
      expect(saved!.messages.last.content, answer.content);
    }, timeout: const Timeout(Duration(minutes: 5)));
  }
}
