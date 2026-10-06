import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import 'chat/chat_controller.dart';
import 'chat/background_execution.dart';
import 'chat/chat_screen.dart';
import 'data/local_image_store.dart';
import 'data/temporary_chat.dart';
import 'data/shared_preferences_driver.dart';
import 'data/sqflite_database.dart';
import 'data/settings_store.dart';
import 'data/chat_sync.dart';
import 'local_network_preflight.dart';
import 'ollama/openai_compatible_client.dart';
import 'ollama/ollama_client.dart';
import 'ollama/web_agent.dart';
import 'ui/design.dart';

class MobOllamaApp extends StatefulWidget {
  const MobOllamaApp({
    super.key,
    required this.controller,
    required this.onDispose,
  });

  final ChatController controller;
  final Future<void> Function() onDispose;

  @override
  State<MobOllamaApp> createState() => _MobOllamaAppState();
}

class _MobOllamaAppState extends State<MobOllamaApp>
    with WidgetsBindingObserver {
  late final Future<void> _initialization = widget.controller.initialize();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(widget.controller.pauseForBackground());
    } else if (state == AppLifecycleState.resumed) {
      unawaited(widget.controller.chatSync?.synchronize(network: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_shutdown());
    super.dispose();
  }

  Future<void> _shutdown() async {
    try {
      await widget.controller.shutdown();
    } finally {
      widget.controller.dispose();
      await widget.onDispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        return MaterialApp(
          title: 'MobileLlama',
          debugShowCheckedModeBanner: false,
          themeMode: _themeMode(widget.controller.themePreference),
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: FutureBuilder<void>(
            future: _initialization,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return _StartupFailure(error: snapshot.error!);
              }
              if (!widget.controller.initialized) {
                return const _StartupInProgress();
              }
              return ChatScreen(controller: widget.controller);
            },
          ),
        );
      },
    );
  }

  static ThemeMode _themeMode(ThemePreference preference) =>
      switch (preference) {
        ThemePreference.system => ThemeMode.system,
        ThemePreference.light => ThemeMode.light,
        ThemePreference.dark => ThemeMode.dark,
      };

  static ThemeData _theme(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    const accent = Design.accent;
    final generated = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.neutral,
    );
    final colors = generated.copyWith(
      primary: accent,
      onPrimary: Colors.white,
      primaryContainer: isDark
          ? const Color(0xFF303A55)
          : const Color(0xFFE0E7FF),
      onPrimaryContainer: isDark
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF171717),
      surface: isDark ? const Color(0xFF171717) : Colors.white,
      surfaceContainerLowest: isDark ? const Color(0xFF171717) : Colors.white,
      surfaceContainerLow: isDark
          ? const Color(0xFF202020)
          : const Color(0xFFF7F7F7),
      surfaceContainer: isDark ? const Color(0xFF262626) : Colors.white,
      surfaceContainerHigh: isDark
          ? const Color(0xFF333333)
          : const Color(0xFFEBEBEB),
      surfaceContainerHighest: isDark
          ? const Color(0xFF303030)
          : const Color(0xFFE1E1E1),
      onSurface: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF171717),
      onSurfaceVariant: isDark
          ? const Color(0xFFB5B5B5)
          : const Color(0xFF686868),
      outline: isDark ? const Color(0xFF777777) : const Color(0xFF929292),
      outlineVariant: isDark
          ? const Color(0xFF383838)
          : const Color(0xFFE4E4E4),
    );
    final base = ThemeData(
      brightness: brightness,
      colorScheme: colors,
      useMaterial3: true,
    );
    final text = base.textTheme;
    final textTheme = text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(
        fontSize: 24,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: -0.3,
      ),
      titleLarge: text.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: -0.2,
      ),
      titleMedium: text.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.30,
        letterSpacing: 0,
      ),
      titleSmall: text.titleSmall?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w500,
        height: 1.35,
        letterSpacing: 0,
      ),
      bodyLarge: text.bodyLarge?.copyWith(
        fontSize: 17,
        fontWeight: FontWeight.w400,
        height: 1.48,
        letterSpacing: 0,
      ),
      bodyMedium: text.bodyMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.45,
        letterSpacing: 0,
      ),
      bodySmall: text.bodySmall?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.40,
        letterSpacing: 0,
      ),
      labelLarge: text.labelLarge?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w500,
        height: 1.30,
        letterSpacing: 0,
      ),
      labelMedium: text.labelMedium?.copyWith(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        height: 1.30,
        letterSpacing: 0,
      ),
      labelSmall: text.labelSmall?.copyWith(
        fontSize: 12,
        fontWeight: FontWeight.w500,
        height: 1.30,
        letterSpacing: 0,
      ),
    );
    return base.copyWith(
      scaffoldBackgroundColor: colors.surface,
      textTheme: textTheme,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: colors.surface,
        foregroundColor: colors.onSurface,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: textTheme.titleMedium?.copyWith(
          color: colors.onSurface,
          fontSize: 17,
          fontWeight: FontWeight.w600,
          height: 1.2,
          letterSpacing: -0.1,
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colors.surfaceContainerLow,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: colors.primary, width: 1.5),
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: colors.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        elevation: 0,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: colors.surfaceContainer,
        modalBackgroundColor: colors.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        dragHandleSize: const Size(38, 5),
        dragHandleColor: colors.onSurface.withValues(alpha: .22),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: isDark ? generated.primary : null,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: isDark ? generated.primary : null,
        ),
      ),
      dividerTheme: DividerThemeData(color: colors.outlineVariant),
    );
  }
}

class _StartupInProgress extends StatelessWidget {
  const _StartupInProgress();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: SafeArea(child: Center(child: CircularProgressIndicator())),
    );
  }
}

/// Shared by the app shell and native workflow previews.
ThemeData mobileLlamaTheme(Brightness brightness) =>
    _MobOllamaAppState._theme(brightness);

class MobOllamaStartupFailure extends StatelessWidget {
  const MobOllamaStartupFailure({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'MobileLlama',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _MobOllamaAppState._theme(Brightness.light),
      darkTheme: _MobOllamaAppState._theme(Brightness.dark),
      home: _StartupFailure(error: error),
    );
  }
}

Future<ChatControllerBootstrap> createChatController() async {
  OpenConversationDatabase? database;
  http.Client? client;
  try {
    final settings = await openSettingsStore();
    await TemporaryChatSession.clearAbandoned();
    final images = await LocalImageAttachmentStore.create();
    database = await openConversationDatabase(
      legacyServerProfileId: settings.activeProfileId,
      referenceCodec: images.referenceCodec,
    );
    final savedDrafts = await database.store.loadDrafts();
    final draftFiles = <String>{
      for (final draft in savedDrafts.values) ...[
        ...List<String>.from(draft['images'] as List? ?? const []),
        if (draft['image'] case final String image) image,
        for (final document in draft['documents'] as List? ?? const [])
          (document as Map)['reference'] as String,
      ],
    };
    await images.reclaimAbandonedIntakeFiles(
      (reference) async =>
          draftFiles.contains(reference) ||
          await database!.store.isAttachmentReferenceInUse(reference),
    );
    client = http.Client();
    const uuid = Uuid();
    final controller = ChatController(
      backgroundExecution: Platform.isIOS
          ? NativeChatBackgroundExecution()
          : NoopChatBackgroundExecution(),
      conversations: database.store,
      settings: settings,
      secrets: const _PlatformSecretStore(FlutterSecureStorage()),
      images: images,
      syncBridge: ChatSyncBridge(),
      localNetworkPreflight: const LocalNetworkPreflight(),
      ollamaClientFactory: (baseUrl) => OllamaClient(
        baseUrl: baseUrl,
        client: client!,
        streamingClientFactory: http.Client.new,
      ),
      openAiCompatibleClientFactory: (baseUrl, apiKey) =>
          OpenAiCompatibleClient(
            baseUrl: baseUrl,
            apiKey: apiKey,
            client: client!,
            streamingClientFactory: http.Client.new,
          ),
      webAgentFactory: ({required ollama, required apiKey}) => WebAgent(
        ollama: ollama,
        webClientFactory: http.Client.new,
        apiKey: apiKey,
      ),
      compatibleWebAgentFactory: ({required client, required apiKey}) =>
          WebAgent.withChatStarter(
            startChat: client.startChat,
            webClientFactory: http.Client.new,
            apiKey: apiKey,
          ),
      idFactory: uuid.v4,
    );
    return ChatControllerBootstrap._(controller, database, client);
  } on Object {
    client?.close();
    await database?.close();
    rethrow;
  }
}

final class ChatControllerBootstrap {
  const ChatControllerBootstrap._(
    this.controller,
    this._database,
    this._client,
  );

  final ChatController controller;
  final OpenConversationDatabase _database;
  final http.Client _client;

  Future<void> close() async {
    _client.close();
    await _database.close();
  }
}

final class _PlatformSecretStore implements SecretStore {
  const _PlatformSecretStore(this._storage);

  final FlutterSecureStorage _storage;

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(
                    Icons.error_outline,
                    size: 32,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Local storage could not be opened.',
                    style: theme.textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    error.toString(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
