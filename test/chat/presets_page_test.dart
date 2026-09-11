import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/chat/presets_page.dart';
import 'package:mobollama/domain/generation_options.dart';

import '../support/chat_fixture.dart';

void main() {
  testWidgets(
    'preset create and edit preserve hidden options and delete leaves chat unchanged',
    (tester) async {
      final fixture = ChatFixture();
      addTearDown(fixture.close);
      await tester.runAsync(() async {
        await fixture.open();
        await fixture.seed('selected');
        await fixture.controller.initialize();
        await fixture.controller.openConversation('selected');
        expect(
          await fixture.controller.updateConversationSettings(
            systemPrompt: 'Original chat instructions',
            generationOptions: const GenerationOptions(
              topP: .77,
              maxTokens: -1,
            ),
          ),
          isTrue,
        );
      });

      await tester.pumpWidget(
        MaterialApp(home: PromptPresetsPage(controller: fixture.controller)),
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create preset'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('preset-name-field')),
        'Careful answer',
      );
      await tester.enterText(find.byType(TextFormField).at(2), '0.25');
      await tester.tap(find.widgetWithText(FilledButton, 'Save preset'));
      await tester.pumpAndSettle();

      expect(fixture.controller.promptPresets.single.name, 'Careful answer');
      expect(
        fixture.controller.promptPresets.single.generationOptions.topP,
        .77,
      );
      expect(
        fixture.controller.promptPresets.single.generationOptions.temperature,
        .25,
      );
      expect(
        fixture.controller.promptPresets.single.generationOptions.maxTokens,
        -1,
      );

      await tester.tap(find.byTooltip('Edit Careful answer'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('preset-name-field')),
        'Revised answer',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Save preset'));
      await tester.pumpAndSettle();
      expect(fixture.controller.promptPresets.single.name, 'Revised answer');
      expect(
        fixture.controller.promptPresets.single.generationOptions.topP,
        .77,
      );

      await tester.tap(find.byTooltip('Delete Revised answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(fixture.controller.promptPresets, hasLength(1));
      await tester.tap(find.byTooltip('Delete Revised answer'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(fixture.controller.promptPresets, isEmpty);
      expect(fixture.controller.systemPrompt, 'Original chat instructions');
      expect(fixture.controller.generationOptions.topP, .77);
    },
  );

  testWidgets('applying a preset requires confirmation and updates this chat', (
    tester,
  ) async {
    final fixture = ChatFixture();
    addTearDown(fixture.close);
    late String originalPrompt;
    await tester.runAsync(() async {
      await fixture.open();
      await fixture.seed('selected');
      await fixture.controller.initialize();
      await fixture.controller.openConversation('selected');
      originalPrompt = fixture.controller.systemPrompt;
      expect(
        await fixture.controller.savePromptPreset(
          name: 'Concise',
          systemPrompt: 'Answer in two sentences.',
          generationOptions: const GenerationOptions(temperature: .2),
        ),
        isTrue,
      );
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => PromptPresetsPage(
                      controller: fixture.controller,
                      allowApply: true,
                    ),
                  ),
                ),
                child: const Text('Open presets'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply to this chat'));
    await tester.pumpAndSettle();
    expect(find.text('Apply preset to this chat?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.controller.systemPrompt, originalPrompt);

    await tester.tap(find.widgetWithText(FilledButton, 'Apply to this chat'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(fixture.controller.systemPrompt, 'Answer in two sentences.');
    expect(fixture.controller.generationOptions.temperature, .2);
  });
}
