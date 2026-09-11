import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/chat/history.dart';
import 'package:mobollama/data/chat_sync.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/domain/conversation.dart';
import 'package:mobollama/settings/settings_page.dart';
import 'package:mobollama/settings/settings_sheet.dart';

import '../support/chat_fixture.dart';

void main() {
  testWidgets(
    'iCloud is hidden when unconfigured and explained when unsupported',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = ChatFixture();
      addTearDown(fixture.close);
      await tester.runAsync(() async {
        await fixture.open();
        await fixture.controller.initialize();
      });

      await tester.pumpWidget(
        MaterialApp(home: SettingsPage(controller: fixture.controller)),
      );
      expect(find.text('Prompt presets'), findsOneWidget);
      expect(find.text('Models on Home'), findsNothing);
      if (!ChatSyncBridge.configured) {
        expect(find.text('iCloud sync'), findsNothing);
        return;
      }
      await tester.dragUntilVisible(
        find.text('iCloud sync'),
        find.byType(ListView),
        const Offset(0, -300),
      );
      await tester.ensureVisible(find.text('iCloud sync'));
      await tester.pumpAndSettle();
      expect(find.text('iCloud sync'), findsOneWidget);
      expect(find.text('Unavailable'), findsOneWidget);

      await tester.tap(find.text('iCloud sync').hitTestable());
      await tester.pumpAndSettle();
      expect(
        find.text(
          'iCloud sync is unavailable. It requires iOS 17 or later and an available iCloud account.',
        ),
        findsOneWidget,
      );
      expect(find.byType(SwitchListTile), findsNothing);
    },
  );

  testWidgets(
    'selected chat row keeps title and server inside padded 48pt target',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = ChatFixture();
      addTearDown(fixture.close);
      late Conversation chat;
      const title =
          'A deliberately long conversation title that must truncate safely';
      const serverName = 'Extremely Long Lab Server Name';
      await tester.runAsync(() async {
        await fixture.open();
        await fixture.settings.upsertProfile(
          ServerProfile(
            id: 'long-server',
            name: serverName,
            protocol: ServerProtocol.ollama,
            baseUrl: 'https://long-server.test',
          ),
        );
        chat = await fixture.seed(
          'layout-chat',
          profile: 'long-server',
          title: title,
        );
        await fixture.controller.initialize();
        await fixture.controller.openConversation(chat.id);
      });

      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SizedBox(
                width: 300,
                child: ChatHistoryRow(
                  chat: chat,
                  controller: fixture.controller,
                  onTap: () {},
                ),
              ),
            ),
          ),
        ),
      );

      final tile = tester.widget<ListTile>(find.byType(ListTile));
      expect(tile.contentPadding, const EdgeInsets.symmetric(horizontal: 12));
      expect(tile.minTileHeight, 48);
      expect(tile.selected, isTrue);
      expect(
        tester.getRect(find.text(chat.title)).right,
        lessThanOrEqualTo(tester.getRect(find.text(serverName)).left),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'browsing another server and choosing its default preserves this chat',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = ChatFixture();
      addTearDown(fixture.close);
      await tester.runAsync(() async {
        await fixture.open();
        await fixture.seed('home-chat');
        await fixture.controller.initialize();
        await fixture.controller.openConversation('home-chat');
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsSheet(
            controller: fixture.controller,
            section: SettingsSection.servers,
          ),
        ),
      );
      await tester.tap(find.byType(DropdownButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lab').last);
      await tester.pumpAndSettle();

      expect(find.text('Saved server'), findsOneWidget);
      expect(find.text('New chats on Lab'), findsOneWidget);
      expect(find.text('New chat on Lab'), findsOneWidget);
      expect(find.text('Models on Lab'), findsOneWidget);
      expect(find.text('Models on Home'), findsNothing);
      expect(fixture.controller.conversation?.id, 'home-chat');
      expect(fixture.controller.activeProfileId, 'home');

      await tester.tap(find.text('Default model'));
      await tester.pumpAndSettle();
      expect(find.text('Default model for Lab'), findsOneWidget);
      await tester.tap(find.text('gemma3:4b'));
      await tester.pumpAndSettle();

      expect(fixture.controller.defaultModelFor('lab'), 'gemma3:4b');
      expect(fixture.controller.defaultModelFor('home'), isNull);
      expect(fixture.controller.conversation?.id, 'home-chat');
      expect(fixture.controller.activeProfileId, 'home');

      await tester.ensureVisible(find.text('Models on Lab'));
      await tester.tap(find.text('Models on Lab'));
      await tester.pumpAndSettle();
      expect(find.text('Models are stored on Lab, not this phone.'), findsOne);
      expect(fixture.controller.conversation?.id, 'home-chat');
      expect(fixture.controller.activeProfileId, 'home');
    },
  );

  testWidgets(
    'Web Agent preference stays visible when this chat model lacks tools',
    (tester) async {
      final fixture = ChatFixture();
      addTearDown(fixture.close);
      await tester.runAsync(() async {
        await fixture.open();
        await fixture.settings.setWebAgentEnabled(true);
        await fixture.seed('vision-chat', model: 'gemma3:4b');
        await fixture.controller.initialize();
        await fixture.controller.openConversation('vision-chat');
      });

      await tester.pumpWidget(
        MaterialApp(
          home: SettingsSheet(
            controller: fixture.controller,
            section: SettingsSection.webAgent,
          ),
        ),
      );

      final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
      expect(toggle.value, isTrue);
      expect(
        find.text(
          'Unavailable in this chat: gemma3:4b does not support tools.',
        ),
        findsOneWidget,
      );
    },
  );
}
