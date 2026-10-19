// Opt-in native acceptance. Supply a private --dart-define-from-file with
// endpoint, email, password, model, chatId, and promptName for a disposable
// server account. The desktop chat must contain indigo62; the named server
// prompt must contain "Reply only with {{code}}.".
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:mobollama/app.dart';
import 'package:mobollama/chat/composer.dart';
import 'package:mobollama/open_webui/accounts_page.dart';
import 'package:mobollama/open_webui/run.dart';
import 'package:mobollama/open_webui/screen.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native sign-in and desktop conversation continuation', (
    tester,
  ) async {
    // Keep synthetic input independent of the simulator's real IME.
    binding.testTextInput.register();
    addTearDown(binding.testTextInput.unregister);
    const endpoint = String.fromEnvironment('endpoint');
    const email = String.fromEnvironment('email');
    const password = String.fromEnvironment('password');
    const chatId = String.fromEnvironment('chatId');
    const promptName = String.fromEnvironment('promptName');
    expect(endpoint, isNotEmpty);
    expect(chatId, isNotEmpty);
    final bootstrap = await createChatController();
    await bootstrap.controller.initialize();
    await tester.pumpWidget(
      MaterialApp(
        theme: mobileLlamaTheme(Brightness.light),
        debugShowCheckedModeBanner: false,
        home: WebUiAccountsPage(accounts: bootstrap.controller.webUiAccounts),
      ),
    );
    await tester.tap(find.text('Connect Open WebUI'));
    await tester.pumpAndSettle();
    Finder field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
    );
    await tester.enterText(field('Server address'), endpoint);
    await tester.pump();
    await tester.tap(
      find.text('Allow unencrypted access on this local network'),
    );
    await tester.enterText(field('Email'), email);
    await tester.enterText(field('Password'), password);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Sign in and connect'));
    await tester.tap(find.text('Sign in and connect'));
    for (
      var i = 0;
      i < 300 && find.byType(WebUiScreen).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(WebUiScreen), findsOneWidget);
    final workspace = tester
        .widget<WebUiScreen>(find.byType(WebUiScreen))
        .workspace;
    for (var i = 0; i < 300 && !workspace.online; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await workspace.open(chatId);
    await tester.pumpAndSettle();
    expect(
      workspace.messages.any((m) => m.content.contains('indigo62')),
      isTrue,
    );
    final composer = find.descendant(
      of: find.byType(ChatComposer),
      matching: find.byType(TextField),
    );
    await tester.enterText(
      composer,
      'What is the new continuity code? Reply only with the code.',
    );
    await tester.pump();
    expect(
      workspace.canSend,
      isTrue,
      reason:
          'online=${workspace.online}, model=${workspace.model}, '
          'busy=${workspace.busy}, diverged=${workspace.diverged}, '
          'error=${workspace.error}',
    );
    await tester.tap(find.byTooltip('Send'));
    for (var i = 0; i < 1200 && workspace.run?.terminal != true; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      workspace.run?.state,
      WebUiRunState.completed,
      reason: workspace.run?.problem ?? workspace.error,
    );
    expect(workspace.messages.last.content.toLowerCase(), contains('indigo62'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('live-shared-native-continuity');
    await tester.tap(find.byTooltip('New shared chat'));
    for (
      var i = 0;
      i < 300 && (workspace.busy || workspace.conversation != null);
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pumpAndSettle();
    expect(workspace.conversation, isNull);
    await tester.enterText(composer, 'Please follow this instruction: ');
    await tester.pump();
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Please follow this instruction: ',
    );
    await tester.tap(find.byTooltip('Chat resources'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Prompts'));
    for (var i = 0; i < 300 && find.text(promptName).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.tap(find.text(promptName));
    await tester.pumpAndSettle();
    await tester.enterText(field('code'), 'amber56');
    await tester.tap(find.text('Insert prompt'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(composer).controller!.text,
      'Please follow this instruction: Reply only with amber56.',
    );
    expect(workspace.run, isNull);
    await tester.tap(find.byTooltip('Send'));
    for (var i = 0; i < 1200 && workspace.run?.terminal != true; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      workspace.run?.state,
      WebUiRunState.completed,
      reason: workspace.run?.problem ?? workspace.error,
    );
    expect(workspace.messages.last.content.toLowerCase(), contains('amber56'));
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await binding.takeScreenshot('live-shared-native-prompt');
    await bootstrap.controller.webUiAccounts.signOut(workspace.session);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await bootstrap.controller.shutdown();
    bootstrap.controller.dispose();
    await bootstrap.close();
  });
}
