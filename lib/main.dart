import 'package:flutter/material.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    final bootstrap = await createChatController();
    runApp(
      MobOllamaApp(
        controller: bootstrap.controller,
        onDispose: bootstrap.close,
      ),
    );
  } on Object catch (error) {
    runApp(MobOllamaStartupFailure(error: error));
  }
}
