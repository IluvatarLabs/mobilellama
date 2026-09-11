import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'chat/chat_controller.dart';
import 'chat/background_execution.dart';
import 'chat/chat_screen.dart';
import 'data/attachment_reference_codec.dart';
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
          : const Color(0xFF2A2E3A),
      surface: isDark ? const Color(0xFF2A2E3A) : Colors.white,
      surfaceContainerLowest: isDark ? const Color(0xFF2A2E3A) : Colors.white,
      surfaceContainerLow: isDark
          ? const Color(0xFF373B47)
          : const Color(0xFFF7F8FA),
      surfaceContainer: isDark ? const Color(0xFF424651) : Colors.white,
      surfaceContainerHigh: isDark
          ? const Color(0xFF50545F)
          : const Color(0xFFE8EBF2),
      surfaceContainerHighest: isDark
          ? const Color(0xFF494D58)
          : const Color(0xFFDDE2EB),
      onSurface: isDark ? const Color(0xFFFFFFFF) : const Color(0xFF2A2E3A),
      onSurfaceVariant: isDark
          ? const Color(0xFFAEB0B5)
          : const Color(0xFF687080),
      outline: isDark ? const Color(0xFF747B89) : const Color(0xFF8F97A6),
      outlineVariant: isDark
          ? const Color(0xFF373B46)
          : const Color(0xFFD6DAE4),
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
    final images = await _LocalImageAttachmentStore.create();
    database = await openConversationDatabase(
      legacyServerProfileId: settings.activeProfileId,
      referenceCodec: images.referenceCodec,
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

final class _LocalImageAttachmentStore implements ImageAttachmentStore {
  const _LocalImageAttachmentStore(this._root, this._picker);

  final Directory _root;
  final ImagePicker _picker;
  AttachmentReferenceCodec get referenceCodec =>
      RootedAttachmentReferenceCodec(_root.path);

  static Future<_LocalImageAttachmentStore> create() async {
    final documents = await getApplicationDocumentsDirectory();
    final root = Directory(path.join(documents.path, 'chat-images'));
    await root.create(recursive: true);
    return _LocalImageAttachmentStore(root, ImagePicker());
  }

  @override
  Future<String?> pickAndCopy({
    required String conversationId,
    bool camera = false,
  }) async {
    final picked = await _picker.pickImage(
      source: camera ? ImageSource.camera : ImageSource.gallery,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 88,
    );
    if (picked == null) return null;
    final directory = _conversationDirectory(conversationId);
    await directory.create(recursive: true);
    final rawExtension = path.extension(picked.name).toLowerCase();
    final extension = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(rawExtension)
        ? rawExtension
        : '.img';
    final target = File(
      path.join(directory.path, '${const Uuid().v4()}$extension'),
    );
    await File(picked.path).copy(target.path);
    if (await target.length() > ChatController.maxImageBytes) {
      await target.delete();
      throw const ChatRequestLimitException(
        'The selected image is larger than 8 MB after resizing.',
      );
    }
    return target.path;
  }

  @override
  Future<String> readAsBase64(String reference) async {
    final file = _validatedFile(reference);
    return base64Encode(await file.readAsBytes());
  }

  @override
  Future<String> writeBytes({
    required String conversationId,
    required List<int> bytes,
    required String sourceName,
  }) async {
    if (bytes.isEmpty || bytes.length > ChatController.maxImageBytes) {
      throw const FormatException('Backup image is empty or exceeds 8 MB.');
    }
    final directory = _conversationDirectory(conversationId);
    await directory.create(recursive: true);
    final extension = path.extension(sourceName).toLowerCase();
    final suffix = RegExp(r'^\.[a-z0-9]{1,8}$').hasMatch(extension)
        ? extension
        : '.img';
    final file = File(path.join(directory.path, '${const Uuid().v4()}$suffix'));
    try {
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } on Object {
      if (await file.exists()) await file.delete();
      rethrow;
    }
  }

  @override
  Future<int> sizeInBytes(String reference) async {
    final stat = await _validatedFile(reference).stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Image file is missing.', reference);
    }
    return stat.size;
  }

  @override
  Future<void> deleteReference(String reference) async {
    final file = _validatedFile(reference);
    if (await file.exists()) await file.delete();
  }

  @override
  Future<void> deleteConversation(String conversationId) async {
    final directory = _conversationDirectory(conversationId);
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  Directory _conversationDirectory(String conversationId) {
    final segment = base64Url
        .encode(utf8.encode(conversationId))
        .replaceAll('=', '');
    return Directory(path.join(_root.path, segment));
  }

  File _validatedFile(String reference) {
    final normalizedRoot = path.normalize(path.absolute(_root.path));
    final normalizedReference = path.normalize(path.absolute(reference));
    if (!path.isWithin(normalizedRoot, normalizedReference)) {
      throw ArgumentError('Image reference is outside app storage.');
    }
    return File(normalizedReference);
  }
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
