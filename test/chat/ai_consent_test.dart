import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/chat/chat_screen.dart';
import 'package:mobollama/data/settings_store.dart';

import '../support/chat_fixture.dart';

void main() {
  for (final protocol in [
    ServerProtocol.ollama,
    ServerProtocol.openAiCompatible,
  ]) {
    testWidgets(
      '${protocol.name}: saved chats send only after exact-server consent',
      (tester) async {
        final f = ChatFixture();
        Future<void> settle() async {
          for (var i = 0; i < 12; i++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 10)),
            );
            await tester.pump(const Duration(milliseconds: 30));
          }
        }

        late ServerProfile profile;
        await tester.runAsync(() async {
          await f.open();
          profile = f.settings.activeProfile.copyWith(protocol: protocol);
          await f.settings.upsertProfile(profile);
          await f.settings.revokeDestination(protocol, profile.baseUrl);
          // The old passive disclosure must not authorize an upgraded install.
          f.preferences.values['acknowledged_destinations_v1'] =
              '["${protocol.name} ${profile.baseUrl}"]';
          await f.controller.initialize();
          f.controller.setDraftText('Keep this private draft');
          await f.controller.testConnection(profile);
          await f.controller.send(f.controller.draftText);
        });
        expect(f.networkRequests, isEmpty);
        await tester.pumpWidget(
          MaterialApp(home: ChatScreen(controller: f.controller)),
        );
        await settle();
        final connect = find.text('Connect to Home to continue');
        await tester.tap(connect);
        await tester.pumpAndSettle();
        expect(find.text('Allow AI data sharing?'), findsOneWidget);
        expect(find.text(profile.baseUrl), findsOneWidget);
        await tester.tap(find.text('Don’t allow'));
        await settle();
        expect(f.networkRequests, isEmpty);
        expect(f.controller.draftText, 'Keep this private draft');
        await tester.tap(connect);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Allow data sharing'));
        await settle();
        await tester.tap(find.byTooltip('Send'));
        await settle();
        expect(f.requests, hasLength(1));
        expect(
          f.networkRequests.every((uri) => uri.host == 'home.test'),
          isTrue,
        );
        expect(f.controller.messages.last.content, isNotEmpty);
        final count = f.networkRequests.length;
        await tester.runAsync(() async {
          f.controller.setDraftText('Keep after withdrawal');
          await f.controller.revokeDestination(profile);
          await f.controller.connectConversation();
          await f.controller.testConnection(profile);
          await f.controller.send(f.controller.draftText);
          await f.controller.regenerateAssistant(f.controller.messages.last.id);
        });
        await settle();
        expect(f.networkRequests, hasLength(count));
        expect(f.controller.draftText, 'Keep after withdrawal');
        expect(f.controller.history, isNotEmpty);
        expect(
          f.settings.isDestinationAcknowledged(protocol, 'https://other.test'),
          isFalse,
        );
        await tester.pumpWidget(const SizedBox());
        var closed = false;
        unawaited(f.close().whenComplete(() => closed = true));
        await settle();
        expect(closed, isTrue);
      },
    );
  }
}
