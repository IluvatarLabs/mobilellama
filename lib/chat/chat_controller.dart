import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:crypto/crypto.dart';

import '../data/conversation_store.dart';
import '../data/chat_backup.dart';
import '../data/chat_sync.dart';
import '../data/document_reader.dart';
import '../data/settings_store.dart';
import '../domain/conversation.dart';
import '../domain/generation_options.dart';
import '../domain/message.dart';
import '../domain/document_attachment.dart';
import '../domain/prompt_preset.dart';
import '../domain/queued_prompt.dart';
import '../domain/tool_call.dart';
import '../local_network_preflight.dart';
import '../ollama/openai_compatible_client.dart';
import '../ollama/ollama_client.dart';
import '../ollama/web_agent.dart';
import 'activity_disclosure.dart';
import 'background_execution.dart';
import 'transcript.dart';

typedef OllamaClientFactory = OllamaClient Function(String baseUrl);
typedef OpenAiCompatibleClientFactory = OpenAiCompatibleClient Function(
  String baseUrl,
  String apiKey,
);

OpenAiCompatibleClient _missingOpenAiCompatibleClientFactory(
  String baseUrl,
  String apiKey,
) => throw UnsupportedError('OpenAI-compatible transport is not configured');
typedef WebAgentFactory = WebAgent Function({
  required OllamaClient ollama,
  required String apiKey,
});
typedef CompatibleWebAgentFactory = WebAgent Function({
  required OpenAiCompatibleClient client,
  required String apiKey,
});
typedef IdFactory = String Function();

String? normalizedServerOrigin(String value) {
  try {
    return OllamaClient.normalizeBaseUrl(value).origin;
  } on FormatException {
    return null;
  }
}

/// Cleartext Ollama connections are limited to hosts that are unambiguously
/// local from the URL alone. Public and ambiguous hostnames must use HTTPS.
bool insecureHttpHostAllowed(String value) {
  Uri uri;
  try {
    uri = OllamaClient.normalizeBaseUrl(value);
  } on FormatException {
    return false;
  }
  if (uri.scheme != 'http') return true;

  var host = uri.host.toLowerCase();
  while (host.endsWith('.')) {
    host = host.substring(0, host.length - 1);
  }
  if (host == 'localhost' ||
      host.endsWith('.localhost') ||
      host.endsWith('.local')) {
    return true;
  }

  final address = InternetAddress.tryParse(host);
  if (address == null) return false;
  final bytes = address.rawAddress;
  if (bytes.length == 4) return _isLocalIpv4(bytes);
  if (bytes.length != 16) return false;

  final ipv4Mapped =
      bytes.take(10).every((byte) => byte == 0) &&
      bytes[10] == 0xff &&
      bytes[11] == 0xff;
  if (ipv4Mapped) return _isLocalIpv4(bytes.sublist(12));

  final loopback = bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
  final uniqueLocal = (bytes[0] & 0xfe) == 0xfc;
  final linkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80;
  return loopback || uniqueLocal || linkLocal;
}

bool _isLocalIpv4(List<int> bytes) {
  final first = bytes[0];
  final second = bytes[1];
  return first == 10 ||
      first == 127 ||
      (first == 100 && second >= 64 && second <= 127) ||
      (first == 169 && second == 254) ||
      (first == 172 && second >= 16 && second <= 31) ||
      (first == 192 && second == 168);
}

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

abstract interface class ImageAttachmentStore {
  Future<String?> pickAndCopy({
    required String conversationId,
    bool camera = false,
  });
  Future<int> sizeInBytes(String reference);
  Future<String> readAsBase64(String reference);
  Future<void> deleteReference(String reference);
  Future<void> deleteConversation(String conversationId);
  Future<String> writeBytes({
    required String conversationId,
    required List<int> bytes,
    required String sourceName,
  });
}

enum ServerConnectionState { disconnected, connecting, connected, error }

final class ChatModelOption {
  const ChatModelOption(this.name);

  final String name;
}

final class _ServerProbe {
  const _ServerProbe({
    required this.profile,
    required this.models,
    this.ollama,
    this.openAiCompatible,
    this.version,
    this.serverApiKey,
  });

  final ServerProfile profile;
  final List<ChatModelOption> models;
  final OllamaClient? ollama;
  final OpenAiCompatibleClient? openAiCompatible;
  final OllamaVersion? version;
  final String? serverApiKey;
}

final class ChatRequestLimitException implements Exception {
  const ChatRequestLimitException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class _ChatDraft {
  String text = '';
  List<String> images = [];
  List<DocumentAttachment> documents = [];
  String? reservedId;
  String? systemPrompt;
  GenerationOptions? options;

  Map<String, Object?> toJson() => {
    'text': text,
    'images': List<String>.of(images),
    'documents': documents.map((document) => document.toJson()).toList(),
    'reservedId': reservedId,
    'systemPrompt': systemPrompt,
    if (options != null) 'options': options!.toOllamaJson(),
  };

  static _ChatDraft fromJson(Map<String, Object?> json) => _ChatDraft()
    ..text = json['text'] as String? ?? ''
    ..images = json['images'] is List
        ? List<String>.from(json['images'] as List)
        : [if (json['image'] case final String image) image]
    ..documents = [
      for (final value in json['documents'] as List? ?? const [])
        DocumentAttachment.fromJson(Map<String, Object?>.from(value as Map)),
    ]
    ..reservedId = json['reservedId'] as String?
    ..systemPrompt = json['systemPrompt'] as String?
    ..options = json['options'] == null
        ? null
        : GenerationOptions.fromJson(
            Map<String, Object?>.from(json['options'] as Map),
          );
}

bool _draftHasPersistentContent(_ChatDraft draft) =>
    draft.text.isNotEmpty ||
    draft.images.isNotEmpty ||
    draft.documents.isNotEmpty ||
    draft.systemPrompt != null ||
    draft.options != null;

/// Immutable provider ownership, independent of the selected screen/server.
final class _RunConfiguration {
  const _RunConfiguration({
    required this.profile,
    this.ollama,
    this.compatible,
    required this.thinking,
    required this.webEnabled,
    this.webKey,
  });
  final ServerProfile profile;
  final OllamaClient? ollama;
  final OpenAiCompatibleClient? compatible;
  final bool thinking;
  final bool webEnabled;
  final String? webKey;
}

final class _ChatRun {
  _ChatRun({
    required this.id,
    required this.thread,
    required this.assistantId,
    required this.configuration,
    this.claim,
    this.restoreOnStartupFailure = false,
  });
  final String id;
  ConversationThread thread;
  final String assistantId;
  final _RunConfiguration configuration;
  final QueuedPromptClaim? claim;
  final bool restoreOnStartupFailure;
  bool stopRequested = false;
  bool finishing = false;
  bool receivedOutput = false;
  OllamaChatStream? chat;
  WebAgentRun? agent;
  StreamIterator<WebAgentEvent>? iterator;
  Timer? checkpointTimer;
  Future<void> checkpointTail = Future<void>.value();
  final Completer<void> finished = Completer<void>();
  final Map<OllamaToolCall, String> syntheticToolIds = Map.identity();
  final Map<int, int> nextToolIndex = {};
  String get conversationId => thread.conversation.id;
}

class ChatController extends ChangeNotifier {
  ChatController({
    required ConversationStore conversations,
    required SettingsStore settings,
    required SecretStore secrets,
    required ImageAttachmentStore images,
    DocumentReader? documentReader,
    ChatSyncBridge? syncBridge,
    ChatBackgroundExecution? backgroundExecution,
    required OllamaClientFactory ollamaClientFactory,
    OpenAiCompatibleClientFactory? openAiCompatibleClientFactory,
    LocalNetworkPreflight? localNetworkPreflight,
    required WebAgentFactory webAgentFactory,
    CompatibleWebAgentFactory? compatibleWebAgentFactory,
    required IdFactory idFactory,
  }) : _conversations = conversations,
       _settingsStore = settings,
       _secrets = secrets,
       _images = images,
       _documentReader = documentReader ?? DocumentReader(),
       _syncBridge = syncBridge,
       _backgroundExecution =
           backgroundExecution ?? NoopChatBackgroundExecution(),
       _ollamaClientFactory = ollamaClientFactory,
       _openAiCompatibleClientFactory =
           openAiCompatibleClientFactory ??
           _missingOpenAiCompatibleClientFactory,
       _localNetworkPreflight = localNetworkPreflight,
       _webAgentFactory = webAgentFactory,
       _compatibleWebAgentFactory = compatibleWebAgentFactory,
       _idFactory = idFactory;

  static const _webApiKeySecret = 'ollama_web_api_key';
  static const _webDisclosureSecret = 'web_agent_disclosure_acknowledged';
  static const maxRequestMessages = 128;
  static const maxMessageTextBytes = 64 * 1024;
  static const maxRequestTextBytes = 512 * 1024;
  static const maxRequestImages = 8;
  static const maxImageBytes = 8 * 1024 * 1024;
  static const maxRequestImageBytes = 24 * 1024 * 1024;

  final ConversationStore _conversations;
  final SettingsStore _settingsStore;
  final SecretStore _secrets;
  final ImageAttachmentStore _images;
  final DocumentReader _documentReader;
  final ChatSyncBridge? _syncBridge;
  final ChatBackgroundExecution _backgroundExecution;
  ChatSyncService? _chatSync;
  ChatSyncService? get chatSync => _chatSync;
  int _syncRevision = 0;
  final OllamaClientFactory _ollamaClientFactory;
  final OpenAiCompatibleClientFactory _openAiCompatibleClientFactory;
  final LocalNetworkPreflight? _localNetworkPreflight;
  final WebAgentFactory _webAgentFactory;
  final CompatibleWebAgentFactory? _compatibleWebAgentFactory;
  final IdFactory _idFactory;

  LocalSettings? _settings;
  OllamaClient? _ollama;
  OpenAiCompatibleClient? _openAiCompatible;
  OllamaVersion? _version;
  List<ChatModelOption> _models = const [];
  final Map<String, List<ChatModelOption>> _profileModels = {};
  OllamaShowResponse? _selectedModelDetails;
  String? _selectedModel;
  List<Conversation> _history = const [];
  ConversationThread? _thread;
  final Map<String, _ChatDraft> _drafts = {};
  String get draftKey => _thread?.conversation.id ?? 'new:$activeProfileId';
  _ChatDraft get _draft => _drafts.putIfAbsent(draftKey, _ChatDraft.new);
  String get draftText => _draft.text;
  void setDraftText(String text) {
    _draft.text = text;
    unawaited(flushDrafts());
  }

  String? get _pendingImageReference => _draft.images.firstOrNull;
  Future<void> _draftWriteTail = Future<void>.value();

  /// Queue immutable snapshots so rapid typing cannot commit out of order.
  Future<void> flushDrafts() {
    final snapshot = {
      for (final entry in _drafts.entries)
        if (_draftHasPersistentContent(entry.value))
          entry.key: entry.value.toJson(),
    };
    _draftWriteTail = _draftWriteTail.then((_) async {
      try {
        await _conversations.saveDrafts(snapshot);
        final hadError = _draftPersistenceError != null;
        _draftPersistenceError = null;
        if (hadError) notifyListeners();
      } on Object catch (error) {
        _draftPersistenceError =
            'Your draft could not be saved: ${_friendlyError(error)}';
        notifyListeners();
      }
    });
    return _draftWriteTail;
  }

  /// Backgrounding is not cancellation. Native expiration owns the Stop path.
  Future<void> pauseForBackground() async {
    await flushDrafts();
    await Future.wait(_runs.values.toList().map(_flushRunCheckpoint));
  }

  bool get hasDraft =>
      draftText.isNotEmpty ||
      _pendingImageReference != null ||
      _draft.documents.isNotEmpty;
  List<DocumentAttachment> get pendingDocuments =>
      List.unmodifiable(_draft.documents);
  String? _serverApiKey;
  String? _webApiKey;
  bool _webDisclosureAcknowledged = false;
  bool _initialized = false;
  bool _modelLoading = false;
  bool _profileMutationBusy = false;
  bool _conversationMutationBusy = false;
  bool _isSubmitting = false;
  final Map<String, _ChatRun> _runs = {};
  final Map<String, List<QueuedPrompt>> _queues = {};
  final Set<String> _queuePausedIds = {};
  final Set<String> _queueStartingIds = {};
  final Set<Future<void>> _queueDrains = {};
  final Map<String, String> _runErrors = {};
  bool get _isStreaming => isConversationRunning(conversation?.id ?? '');
  int _draftScopeRevision = 0;
  Completer<void>? _submissionCompleter;
  Future<void>? _shutdownFuture;
  ServerConnectionState _connectionState = ServerConnectionState.disconnected;
  String? _errorMessage;
  String? _draftPersistenceError;
  String? _contextNotice;
  String? _contextNoticeConversationId;
  String? get contextNotice =>
      _contextNoticeConversationId == conversation?.id ? _contextNotice : null;
  final Set<String> _storedServerApiKeySecrets = <String>{};

  bool get initialized => _initialized;
  bool get _profileChangesBlocked =>
      _isSubmitting ||
      _queueStartingIds.isNotEmpty ||
      _modelLoading ||
      _profileMutationBusy ||
      _conversationMutationBusy ||
      _shutdownFuture != null;
  ServerConnectionState get connectionState => _connectionState;
  bool get isConnected => _connectionState == ServerConnectionState.connected;
  bool get isConnecting => _connectionState == ServerConnectionState.connecting;
  bool get profileMutationBusy => _profileMutationBusy;
  bool get conversationMutationBusy => _conversationMutationBusy;
  String? get version => _version?.version;
  String? get errorMessage {
    final errors = [
      if (_errorMessage != null) _errorMessage!,
      if (_runErrors[conversation?.id] case final error?) error,
      if (_draftPersistenceError != null) _draftPersistenceError!,
    ];
    return errors.isEmpty ? null : errors.join('\n');
  }

  LocalSettings? get settings => _settings;
  String get baseUrl => _settings?.baseUrl ?? SettingsStore.defaultBaseUrl;
  ServerProtocol get serverProtocol =>
      _settings?.serverProtocol ?? ServerProtocol.ollama;
  String get serverDescription => switch (serverProtocol) {
    ServerProtocol.ollama =>
      version == null || version!.isEmpty ? 'Ollama' : 'Ollama $version',
    ServerProtocol.openAiCompatible => 'OpenAI-compatible',
  };
  ThemePreference get themePreference =>
      _settings?.theme ?? ThemePreference.system;
  bool get insecureLanAcknowledged =>
      _settings?.insecureLanAcknowledged ?? false;
  String? get acknowledgedInsecureOrigin =>
      insecureLanAcknowledged ? normalizedServerOrigin(baseUrl) : null;
  bool get isInsecureHttp {
    final uri = Uri.tryParse(baseUrl);
    return uri?.scheme == 'http';
  }

  List<ServerProfile> get profiles => _settingsStore.listProfiles();
  String get activeProfileId => _settingsStore.activeProfileId;
  ServerProfile get activeProfile => _settingsStore.activeProfile;

  bool hasServerApiKeyForProfile(String id) {
    final profile = _profileById(id);
    if (profile == null ||
        profile.protocol != ServerProtocol.openAiCompatible) {
      return false;
    }
    try {
      return _storedServerApiKeySecrets.contains(
        _serverApiKeySecret(profile.protocol, profile.baseUrl),
      );
    } on FormatException {
      return false;
    }
  }

  List<ChatModelOption> get models => _models;
  List<ChatModelOption> modelsForProfile(String profileId) =>
      profileId == activeProfileId
      ? _models
      : _profileModels[profileId] ?? const <ChatModelOption>[];
  void _setProfileModels(String profileId, List<ChatModelOption> models) {
    _profileModels[profileId] = models;
    if (profileId != activeProfileId) return;
    _models = models;
    if (_selectedModel != null &&
        !models.any((model) => model.name == _selectedModel)) {
      _selectedModel = null;
      _selectedModelDetails = null;
    }
  }

  String? get selectedModel => _selectedModel;
  OllamaShowResponse? get selectedModelDetails => _selectedModelDetails;
  final Map<String, OllamaShowResponse> _modelDetails = {};
  OllamaShowResponse? detailsForModel(String model, {String? profileId}) =>
      _modelDetails['${profileId ?? activeProfileId}:$model'];

  /// Read capabilities without changing the conversation's selected model.
  Future<void> loadModelCapabilities({String? profileId}) async {
    final id = profileId ?? activeProfileId;
    if (!canChangeContext) return;
    final profile = _profileById(id);
    if (profile == null) return;

    _profileMutationBusy = true;
    _modelManagementBusy = true;
    _modelManagementProfileId = id;
    _modelManagementError = null;
    _modelManagementStatus = 'Loading model details…';
    notifyListeners();
    try {
      final probe = await _probeServerProfile(profile);
      if (_shutdownFuture != null) return;
      _setProfileModels(id, probe.models);
      if (probe.openAiCompatible != null) {
        for (final model in probe.models) {
          _modelDetails['$id:${model.name}'] = _compatibleDetailsForProfile(
            id,
            model.name,
            probe.openAiCompatible,
          );
        }
        _modelManagementStatus = null;
        notifyListeners();
        return;
      }
      final client = probe.ollama!;
      for (final model in probe.models) {
        final key = '$id:${model.name}';
        if (_modelDetails.containsKey(key)) continue;
        try {
          _modelDetails[key] = await client.showModel(model.name);
          notifyListeners();
        } on Object {
          // An unavailable capability response must not block model selection.
        }
      }
      _modelManagementStatus = null;
    } on Object catch (error) {
      _modelManagementError = _friendlyError(error);
      _modelManagementStatus = null;
    } finally {
      _modelManagementBusy = false;
      _profileMutationBusy = false;
      notifyListeners();
    }
  }

  Set<String> get compatibleCapabilityOverrides =>
      _settingsStore.compatibleCapabilities(activeProfileId);

  Set<String> compatibleCapabilitiesForProfile(String id) =>
      _settingsStore.compatibleCapabilities(id);

  OllamaShowResponse _compatibleDetails(String model) =>
      _compatibleDetailsForProfile(activeProfileId, model, _openAiCompatible);

  OllamaShowResponse _compatibleDetailsForProfile(
    String profileId,
    String model,
    OpenAiCompatibleClient? client,
  ) {
    final metadata = client?.modelMetadata.where((m) => m.id == model);
    final declared = metadata == null || metadata.isEmpty
        ? null
        : metadata.first.capabilities;
    return OllamaShowResponse.fromJson({
      'capabilities': {
        ...?declared,
        ...compatibleCapabilitiesForProfile(profileId),
      }.toList(),
    });
  }

  Future<void> setCompatibleCapability(
    String capability,
    bool enabled, {
    String? profileId,
  }) async {
    final id = profileId ?? activeProfileId;
    if (!canChangeContext ||
        _profileById(id)?.protocol != ServerProtocol.openAiCompatible)
      return;
    final values = Set<String>.of(compatibleCapabilitiesForProfile(id));
    enabled ? values.add(capability) : values.remove(capability);
    await _settingsStore.setCompatibleCapabilities(id, values);
    if (id == activeProfileId) {
      _modelDetails.clear();
      if (_selectedModel != null)
        _selectedModelDetails = _compatibleDetails(_selectedModel!);
    }
    notifyListeners();
  }

  bool get modelLoading => _modelLoading;
  bool _modelManagementBusy = false;
  bool get modelManagementBusy => _modelManagementBusy;
  bool get canManageModels =>
      canChangeContext && isConnected && _ollama != null;
  bool canManageModelsForProfile(String profileId) =>
      canChangeContext &&
      _profileById(profileId)?.protocol == ServerProtocol.ollama;
  String? _modelManagementProfileId;
  String? get modelManagementProfileId => _modelManagementProfileId;
  bool modelManagementBusyForProfile(String profileId) =>
      _modelManagementProfileId == profileId && _modelManagementBusy;
  String? _modelManagementStatus;
  String? get modelManagementStatus => _modelManagementStatus;
  String? modelManagementStatusForProfile(String profileId) =>
      _modelManagementProfileId == profileId ? _modelManagementStatus : null;
  String? _modelManagementError;
  String? get modelManagementError => _modelManagementError;
  String? modelManagementErrorForProfile(String profileId) =>
      _modelManagementProfileId == profileId ? _modelManagementError : null;
  double? _modelDownloadProgress;
  double? get modelDownloadProgress => _modelDownloadProgress;
  double? modelDownloadProgressForProfile(String profileId) =>
      _modelManagementProfileId == profileId ? _modelDownloadProgress : null;
  OllamaModelPull? _modelPull;
  bool get modelPullActive => _modelPull != null;
  bool modelPullActiveForProfile(String profileId) =>
      _modelManagementProfileId == profileId && _modelPull != null;
  Completer<void>? _modelOperation;

  Future<bool> pullModel(String name, {String? profileId}) => _manageModel(
    name,
    profileId: profileId ?? activeProfileId,
    deleting: false,
  );
  Future<bool> deleteModel(String name, {String? profileId}) => _manageModel(
    name,
    profileId: profileId ?? activeProfileId,
    deleting: true,
  );

  Future<bool> _manageModel(
    String name, {
    required String profileId,
    required bool deleting,
  }) async {
    if (!canManageModelsForProfile(profileId)) return false;
    final profile = _profileById(profileId)!;
    _conversationMutationBusy = true;
    _modelManagementBusy = true;
    _modelManagementProfileId = profileId;
    _modelManagementError = null;
    _modelDownloadProgress = null;
    _modelManagementStatus = deleting
        ? 'Deleting ${name.trim()}…'
        : 'Starting download…';
    final operation = Completer<void>();
    _modelOperation = operation;
    notifyListeners();
    try {
      final client = (await _probeServerProfile(profile)).ollama!;
      if (deleting) {
        await client.deleteModel(name);
        _modelManagementStatus = 'Deleted ${name.trim()}.';
      } else {
        final pull = client.startModelPull(name);
        _modelPull = pull;
        var success = false;
        await for (final progress in pull.stream) {
          _modelManagementStatus = progress.status;
          _modelDownloadProgress = progress.fraction;
          success = progress.isSuccess;
          notifyListeners();
        }
        if (pull.isCancelled) {
          _modelManagementStatus = 'Download cancelled.';
          return false;
        }
        if (!success)
          throw StateError('The server did not finish the download.');
        _modelManagementStatus = 'Downloaded ${name.trim()}.';
      }
      final installed = await client.listModels();
      final updatedModels = List<ChatModelOption>.unmodifiable(
        installed.map((model) => ChatModelOption(model.name)),
      );
      _setProfileModels(profileId, updatedModels);
      _modelDetails.removeWhere((key, _) => key.startsWith('$profileId:'));
      return true;
    } on Object catch (error) {
      if (_modelPull?.isCancelled ?? false) {
        _modelManagementStatus = 'Download cancelled.';
      } else {
        _modelManagementError = _friendlyError(error);
        _modelManagementStatus = null;
      }
      return false;
    } finally {
      _modelPull = null;
      _modelManagementBusy = false;
      _conversationMutationBusy = false;
      _modelOperation = null;
      operation.complete();
      notifyListeners();
    }
  }

  Future<void> cancelModelPull({String? profileId}) async {
    if (profileId != null && profileId != _modelManagementProfileId) return;
    final operation = _modelOperation?.future;
    await _modelPull?.cancel();
    await operation;
  }

  bool get supportsImages => _selectedModelDetails?.supportsVision ?? false;
  bool get supportsThinking => _selectedModelDetails?.supportsThinking ?? false;
  bool get supportsTools => _selectedModelDetails?.supportsTools ?? false;

  List<Conversation> get history => _history;
  List<Conversation> get visibleHistory =>
      _history.where((c) => !c.isArchived).toList(growable: false);
  List<Conversation> get archivedHistory =>
      _history.where((c) => c.isArchived).toList(growable: false);
  ServerProfile get conversationProfile =>
      _profileById(_thread?.conversation.serverProfileId ?? activeProfileId) ??
      activeProfile;
  bool get conversationConnected =>
      isConnected &&
      (_thread == null ||
          _thread!.conversation.serverProfileId == activeProfileId);
  bool get canChangeContext => !_profileChangesBlocked;
  bool get canSend =>
      conversationConnected &&
      _selectedModel != null &&
      !_profileChangesBlocked &&
      !_isStreaming &&
      queuedPrompts.isEmpty;
  bool get canQueueOrSend =>
      conversationConnected &&
      _selectedModel != null &&
      !_profileChangesBlocked;
  bool isConversationRunning(String id) =>
      _runs.containsKey(id) || _queueStartingIds.contains(id);
  List<QueuedPrompt> get queuedPrompts =>
      List.unmodifiable(_queues[conversation?.id] ?? const <QueuedPrompt>[]);
  bool get queuePaused =>
      queuedPrompts.isNotEmpty && _queuePausedIds.contains(conversation?.id);
  Future<List<ConversationSearchResult>> searchConversations(String text) =>
      _conversations.search(text);
  Conversation? get conversation => _thread?.conversation;
  List<Message> get messages => _thread?.messages ?? const [];
  String get systemPrompt =>
      _thread?.conversation.systemPrompt ??
      _draft.systemPrompt ??
      chatDefaults.systemPrompt;
  GenerationOptions get generationOptions =>
      _thread?.conversation.generationOptions ??
      _draft.options ??
      chatDefaults.generationOptions;
  String? get pendingImageReference => _pendingImageReference;
  List<String> get pendingImageReferences => List.unmodifiable(_draft.images);
  bool get isSubmitting => _isSubmitting;
  bool get isStreaming => _isStreaming;
  int get draftScopeRevision => _draftScopeRevision;
  bool get hasServerApiKey => _serverApiKey?.isNotEmpty ?? false;
  bool get hasWebApiKey => _webApiKey?.isNotEmpty ?? false;
  bool get webDisclosureAcknowledged => _webDisclosureAcknowledged;
  bool get webAgentEnabled => _settings?.webAgentEnabled ?? false;
  bool get webAgentEffective =>
      webAgentEnabled &&
      _webDisclosureAcknowledged &&
      hasWebApiKey &&
      supportsTools;

  List<TranscriptMessageView> get transcriptMessages {
    final visible = messages
        .where((message) => message.role != MessageRole.tool)
        .toList(growable: false);
    final latestAssistant = visible.lastIndexWhere(
      (message) => message.role == MessageRole.assistant,
    );
    return List<TranscriptMessageView>.unmodifiable([
      for (var index = 0; index < visible.length; index++)
        _toTranscriptMessage(
          visible[index],
          canRetry: index == latestAssistant,
        ),
    ]);
  }

  Future<void> initialize() async {
    if (_initialized) return;
    await _settingsStore.migrateLegacyProfile();
    final savedDrafts = await _conversations.loadDrafts();
    for (final entry in savedDrafts.entries) {
      _drafts[entry.key] = _ChatDraft.fromJson(entry.value);
    }
    await _reloadQueues();
    _queuePausedIds.addAll(_queues.keys);
    _settings = _settingsStore.load();
    await _refreshStoredServerApiKeySecrets();
    if (serverProtocol == ServerProtocol.openAiCompatible) {
      _serverApiKey = (await _secrets.read(
        _serverApiKeySecret(serverProtocol, baseUrl),
      ))?.trim();
    }
    _webApiKey = (await _secrets.read(_webApiKeySecret))?.trim();
    _webDisclosureAcknowledged =
        await _secrets.read(_webDisclosureSecret) == 'true';
    await _reloadHistory();
    _initialized = true;
    if (_syncBridge != null) {
      _chatSync = ChatSyncService(
        bridge: _syncBridge,
        source: this,
        canRun: () =>
            initialized &&
            canChangeContext &&
            _runs.isEmpty &&
            _queues.isEmpty &&
            _queueStartingIds.isEmpty,
        revision: () => '$_syncRevision',
        setContextBusy: (busy) {
          _conversationMutationBusy = busy;
          notifyListeners();
        },
        localVersions: _syncLocalVersions,
        exportChat: _exportSyncChat,
        applyChange: _applySyncChange,
        hasReceipt: _conversations.hasSyncReceipt,
        loadBaseline: () => _settingsStore.syncBaseline,
        saveBaseline: _settingsStore.saveSyncBaseline,
      )..addListener(notifyListeners);
      await _chatSync!.initialize();
    }
    notifyListeners();

    if (isInsecureHttp && !insecureLanAcknowledged) return;
    await connectToServer(
      baseUrl,
      protocol: serverProtocol,
      acknowledgedInsecureOrigin: acknowledgedInsecureOrigin,
      persist: false,
    );
  }

  Future<bool> connectToServer(
    String value, {
    ServerProtocol protocol = ServerProtocol.ollama,
    required String? acknowledgedInsecureOrigin,
    String? serverApiKey,
    bool persist = true,
  }) async {
    if (_profileChangesBlocked) return false;
    final currentProfile = activeProfile;
    late final ServerProfile candidate;
    try {
      candidate = ServerProfile(
        id: currentProfile.id,
        name: currentProfile.name,
        protocol: protocol,
        baseUrl: _canonicalServerBaseUrl(protocol, value),
        acknowledgedInsecureOrigin: acknowledgedInsecureOrigin,
      );
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
      notifyListeners();
      return false;
    }
    final previousConnectionState = _connectionState;
    _connectionState = ServerConnectionState.connecting;
    _errorMessage = null;
    notifyListeners();
    final connected = persist
        ? await upsertServerProfile(
            candidate,
            serverApiKey: serverApiKey,
            makeActive: true,
          )
        : await _activateUnpersistedProfile(
            candidate,
            serverApiKey: serverApiKey,
          );
    if (!connected && _connectionState == ServerConnectionState.connecting) {
      _connectionState = previousConnectionState;
      notifyListeners();
    }
    return connected;
  }

  Future<bool> testServerProfile(
    ServerProfile profile, {
    String? serverApiKey,
  }) async {
    if (_profileChangesBlocked) return false;
    _profileMutationBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _probeServerProfile(profile, serverApiKey: serverApiKey);
      return true;
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
      return false;
    } finally {
      _profileMutationBusy = false;
      notifyListeners();
    }
  }

  /// Probes before writing either the profile or a newly entered API key.
  /// Passing a blank key preserves and uses any key stored for the exact URL.
  Future<bool> upsertServerProfile(
    ServerProfile profile, {
    String? serverApiKey,
    bool makeActive = false,
    bool preserveConversation = false,
  }) async {
    if (_profileChangesBlocked) return false;
    _profileMutationBusy = true;
    _errorMessage = null;
    String? writtenSecret;
    String? replacedSecretValue;
    var profilePersisted = false;
    notifyListeners();
    try {
      final previousActiveId = activeProfileId;
      final previousActiveProfile = activeProfile;
      final previousProfile = _profileById(profile.id);
      final activeIdentityChanged =
          profile.id == previousActiveId &&
          !_sameServerIdentity(previousActiveProfile, profile);
      if (previousProfile != null) {
        final identityChanged = !_sameServerIdentity(previousProfile, profile);
        if (identityChanged &&
            await _conversations.hasConversations(profile.id)) {
          throw const FormatException(
            'Create a new profile for a different server.',
          );
        }
      }
      final previousSecret = previousProfile == null
          ? null
          : _serverSecretForProfile(previousProfile);
      final probe = await _probeServerProfile(
        profile,
        serverApiKey: serverApiKey,
      );
      if (_shutdownFuture != null) return false;
      final shouldActivate = makeActive || profile.id == previousActiveId;

      final enteredKey = serverApiKey?.trim() ?? '';
      if (probe.profile.protocol == ServerProtocol.openAiCompatible &&
          enteredKey.isNotEmpty) {
        final secret = _serverApiKeySecret(
          probe.profile.protocol,
          probe.profile.baseUrl,
        );
        replacedSecretValue = await _secrets.read(secret);
        await _secrets.write(secret, enteredKey);
        writtenSecret = secret;
        _storedServerApiKeySecrets.add(secret);
      } else if (probe.profile.protocol == ServerProtocol.openAiCompatible &&
          (probe.serverApiKey?.isNotEmpty ?? false)) {
        _storedServerApiKeySecrets.add(
          _serverApiKeySecret(probe.profile.protocol, probe.profile.baseUrl),
        );
      }
      await _settingsStore.upsertProfile(probe.profile);
      profilePersisted = true;
      if (activeIdentityChanged) {
        _draftScopeRevision += 1;
        notifyListeners();
      }
      final currentSecret = _serverSecretForProfile(probe.profile);
      final keyCleanupWarning =
          previousSecret != null && previousSecret != currentSecret
          ? await _deleteServerSecretIfOrphaned(previousSecret)
          : null;
      if (makeActive) {
        await _settingsStore.setActiveProfile(probe.profile.id);
        if (probe.profile.id != previousActiveId) {
          _draftScopeRevision += 1;
          notifyListeners();
        }
      }
      if (shouldActivate) {
        await _commitServerProbe(
          probe,
          preserveConversation: preserveConversation,
        );
      }
      if (keyCleanupWarning != null) _errorMessage = keyCleanupWarning;
      return true;
    } on Object catch (error) {
      if (!profilePersisted && writtenSecret != null) {
        try {
          final previous = replacedSecretValue?.trim() ?? '';
          if (previous.isEmpty) {
            await _secrets.delete(writtenSecret);
            _storedServerApiKeySecrets.remove(writtenSecret);
          } else {
            await _secrets.write(writtenSecret, replacedSecretValue!);
            _storedServerApiKeySecrets.add(writtenSecret);
          }
        } on Object {
          // Keep the original save/probe failure as the visible error.
        }
      }
      _errorMessage = _friendlyError(error);
      return false;
    } finally {
      _profileMutationBusy = false;
      notifyListeners();
    }
  }

  Future<bool> switchServerProfile(
    String id, {
    bool preserveConversation = false,
  }) async {
    if (_profileChangesBlocked) return false;
    final profile = _profileById(id);
    if (profile == null) return false;
    final previousActiveId = activeProfileId;
    _profileMutationBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final probe = await _probeServerProfile(profile);
      if (_shutdownFuture != null) return false;
      await _settingsStore.setActiveProfile(probe.profile.id);
      if (probe.profile.id != previousActiveId) {
        _draftScopeRevision += 1;
        notifyListeners();
      }
      await _commitServerProbe(
        probe,
        preserveConversation: preserveConversation,
      );
      return true;
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
      return false;
    } finally {
      _profileMutationBusy = false;
      notifyListeners();
    }
  }

  Future<bool> deleteServerProfile(String id) async {
    if (_profileChangesBlocked) return false;
    final currentProfiles = profiles;
    final index = currentProfiles.indexWhere((profile) => profile.id == id);
    if (index < 0) return false;
    if (currentProfiles.length == 1) {
      _errorMessage = 'The last server profile cannot be deleted.';
      notifyListeners();
      return false;
    }
    final unsentDraft = _drafts['new:$id'];
    if (unsentDraft != null && _draftHasPersistentContent(unsentDraft)) {
      _errorMessage =
          'This server has an unsent draft. Open this server and send or '
          'discard the draft before deleting it.';
      notifyListeners();
      return false;
    }

    _profileMutationBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      if (await _conversations.hasConversations(id)) {
        throw const FormatException("Delete this profile's chats first.");
      }
      final deletedSecret = _serverSecretForProfile(currentProfiles[index]);
      _ServerProbe? fallbackProbe;
      if (id == activeProfileId) {
        final remaining = List<ServerProfile>.of(currentProfiles)
          ..removeAt(index);
        final fallbackIndex = index < remaining.length
            ? index
            : remaining.length - 1;
        final fallback = remaining[fallbackIndex];
        fallbackProbe = await _probeServerProfile(fallback);
        if (_shutdownFuture != null) return false;
      }
      await _settingsStore.deleteProfile(id);
      if (fallbackProbe != null) {
        _draftScopeRevision += 1;
        notifyListeners();
        await _commitServerProbe(fallbackProbe);
      }
      if (deletedSecret != null) {
        final warning = await _deleteServerSecretIfOrphaned(deletedSecret);
        if (warning != null) _errorMessage = warning;
      }
      return true;
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
      return false;
    } finally {
      _profileMutationBusy = false;
      notifyListeners();
    }
  }

  Future<bool> _activateUnpersistedProfile(
    ServerProfile profile, {
    String? serverApiKey,
  }) async {
    if (_profileMutationBusy) return false;
    final previousProfile = activeProfile;
    _profileMutationBusy = true;
    try {
      final probe = await _probeServerProfile(
        profile,
        serverApiKey: serverApiKey,
      );
      if (_shutdownFuture != null) return false;
      if (!_sameServerIdentity(previousProfile, probe.profile)) {
        _draftScopeRevision += 1;
        notifyListeners();
      }
      await _commitServerProbe(probe);
      return true;
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
      return false;
    } finally {
      _profileMutationBusy = false;
      notifyListeners();
    }
  }

  Future<_ServerProbe> _probeServerProfile(
    ServerProfile profile, {
    String? serverApiKey,
  }) async {
    final normalized = ServerProfile(
      id: profile.id,
      name: profile.name,
      protocol: profile.protocol,
      baseUrl: _canonicalServerBaseUrl(profile.protocol, profile.baseUrl),
      acknowledgedInsecureOrigin: profile.acknowledgedInsecureOrigin,
    );
    final uri = Uri.parse(normalized.baseUrl);
    if (uri.scheme == 'http') {
      if (!insecureHttpHostAllowed(normalized.baseUrl)) {
        throw const FormatException(
          'HTTP is allowed only for localhost, .local hosts, and private or link-local IP addresses. Use HTTPS for other hosts.',
        );
      }
      if (!normalized.insecureLanAcknowledged) {
        throw const FormatException(
          'Confirm that HTTP traffic is unencrypted before connecting.',
        );
      }
      await _localNetworkPreflight?.prepare(
        host: uri.host,
        port: uri.hasPort ? uri.port : 80,
      );
    }

    switch (normalized.protocol) {
      case ServerProtocol.ollama:
        final client = _ollamaClientFactory(normalized.baseUrl);
        final version = await client.getVersion();
        final models = await client.listModels();
        return _ServerProbe(
          profile: normalized,
          ollama: client,
          version: version,
          models: List<ChatModelOption>.unmodifiable(
            models.map((model) => ChatModelOption(model.name)),
          ),
        );
      case ServerProtocol.openAiCompatible:
        final enteredKey = serverApiKey?.trim() ?? '';
        final key = enteredKey.isNotEmpty
            ? enteredKey
            : (await _secrets.read(
                    _serverApiKeySecret(
                      normalized.protocol,
                      normalized.baseUrl,
                    ),
                  ))?.trim() ??
                  '';
        final client = _openAiCompatibleClientFactory(normalized.baseUrl, key);
        final models = await client.listModels();
        return _ServerProbe(
          profile: normalized,
          openAiCompatible: client,
          serverApiKey: key,
          models: List<ChatModelOption>.unmodifiable(
            models.map(ChatModelOption.new),
          ),
        );
    }
  }

  Future<void> _commitServerProbe(
    _ServerProbe probe, {
    bool preserveConversation = false,
  }) async {
    _modelDetails.removeWhere(
      (key, _) => key.startsWith('${probe.profile.id}:'),
    );
    _ollama = probe.ollama;
    _openAiCompatible = probe.openAiCompatible;
    _version = probe.version;
    _serverApiKey = probe.serverApiKey;
    _models = probe.models;
    _profileModels[probe.profile.id] = probe.models;
    _selectedModel = null;
    _selectedModelDetails = null;
    _settings = _settingsStore.load();
    _connectionState = ServerConnectionState.connected;
    _errorMessage = null;
    if (!preserveConversation &&
        _thread != null &&
        _thread!.conversation.serverProfileId != activeProfileId) {
      _thread = null;
      _draftScopeRevision += 1;
    }
    await _reloadHistory();
    final stored =
        _thread?.conversation.selectedModel ??
        _settingsStore.defaultModel(activeProfileId) ??
        _settingsStore.lastSelectedModel(activeProfileId);
    final installed = _models.any((model) => model.name == stored);
    final next = installed
        ? stored
        : (_thread == null && _models.isNotEmpty ? _models.first.name : null);
    if (next != null && conversationConnected) {
      if (_isStreaming) {
        _selectedModel = next;
        _selectedModelDetails = _modelDetails['$activeProfileId:$next'];
      } else {
        await selectModel(next);
      }
    }
    notifyListeners();
  }

  static String _canonicalServerBaseUrl(
    ServerProtocol protocol,
    String value,
  ) => switch (protocol) {
    ServerProtocol.ollama => OllamaClient.normalizeBaseUrl(value).toString(),
    ServerProtocol.openAiCompatible => OpenAiCompatibleClient.normalizeBaseUrl(
      value,
    ).toString(),
  };

  static bool _sameServerIdentity(ServerProfile first, ServerProfile second) =>
      first.protocol == second.protocol &&
      _canonicalServerBaseUrl(first.protocol, first.baseUrl) ==
          _canonicalServerBaseUrl(second.protocol, second.baseUrl);

  static String _serverApiKeySecret(ServerProtocol protocol, String value) {
    final canonical = _canonicalServerBaseUrl(protocol, value);
    final encoded = base64Url.encode(utf8.encode(canonical));
    return 'server_api_key:${protocol.name}:$encoded';
  }

  ServerProfile? _profileById(String id) {
    for (final profile in profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  Future<void> _refreshStoredServerApiKeySecrets() async {
    _storedServerApiKeySecrets.clear();
    for (final profile in profiles) {
      if (profile.protocol != ServerProtocol.openAiCompatible) continue;
      final secret = _serverApiKeySecret(profile.protocol, profile.baseUrl);
      final value = (await _secrets.read(secret))?.trim() ?? '';
      if (value.isNotEmpty) _storedServerApiKeySecrets.add(secret);
    }
  }

  String? _serverSecretForProfile(ServerProfile profile) =>
      profile.protocol == ServerProtocol.openAiCompatible
      ? _serverApiKeySecret(profile.protocol, profile.baseUrl)
      : null;

  Future<String?> _deleteServerSecretIfOrphaned(String secret) async {
    final stillUsed = profiles.any(
      (profile) => _serverSecretForProfile(profile) == secret,
    );
    if (stillUsed) return null;
    try {
      await _secrets.delete(secret);
      _storedServerApiKeySecrets.remove(secret);
      return null;
    } on Object {
      return 'The server profiles changed, but an unused API key could not be removed.';
    }
  }

  Future<void> refreshModels() async {
    final ollama = _ollama;
    final openAiCompatible = _openAiCompatible;
    if ((ollama == null && openAiCompatible == null) ||
        _isStreaming ||
        _isSubmitting ||
        _modelLoading ||
        _profileMutationBusy ||
        _conversationMutationBusy) {
      return;
    }
    _modelLoading = true;
    notifyListeners();
    try {
      if (openAiCompatible != null) {
        final names = await openAiCompatible.listModels();
        _models = List.unmodifiable(names.map(ChatModelOption.new));
        _modelDetails.removeWhere(
          (key, _) => key.startsWith('$activeProfileId:'),
        );
        for (final name in names) {
          _modelDetails['$activeProfileId:$name'] = _compatibleDetails(name);
        }
        if (_selectedModel != null) {
          _selectedModelDetails = _compatibleDetails(_selectedModel!);
        }
      } else {
        final models = await ollama!.listModels();
        _models = List.unmodifiable(
          models.map((model) => ChatModelOption(model.name)),
        );
      }
      if (_selectedModel != null &&
          !_models.any((model) => model.name == _selectedModel)) {
        _selectedModel = null;
        _selectedModelDetails = null;
      }
      _errorMessage = null;
      notifyListeners();
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
    } finally {
      _modelLoading = false;
      notifyListeners();
    }
  }

  Future<bool> selectModel(String model) async {
    if (!conversationConnected ||
        (_isStreaming && model != conversation?.selectedModel) ||
        (queuedPrompts.isNotEmpty && model != conversation?.selectedModel) ||
        _isSubmitting ||
        _modelLoading ||
        !_models.any((candidate) => candidate.name == model)) {
      return false;
    }
    _modelLoading = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final details = serverProtocol == ServerProtocol.ollama
          ? await _ollama!.showModel(model)
          : _compatibleDetails(model);
      final current = _thread?.conversation;
      if (current != null && current.selectedModel != model) {
        await _conversations.updateConversationContext(
          id: current.id,
          selectedModel: model,
          systemPrompt: current.systemPrompt,
        );
        _thread = ConversationThread(
          conversation: _copyConversation(
            current,
            selectedModel: model,
            updatedAt: DateTime.now().toUtc(),
          ),
          messages: messages,
        );
        await _reloadHistory();
      }
      _selectedModel = model;
      _selectedModelDetails = details;
      _modelDetails['$activeProfileId:$model'] = details;
      await _settingsStore.rememberModel(activeProfileId, model);
      return true;
    } on Object catch (error) {
      _errorMessage = 'Model could not be selected: ${_friendlyError(error)}';
      return false;
    } finally {
      _modelLoading = false;
      notifyListeners();
    }
  }

  Future<void> newConversation() async {
    if (_profileChangesBlocked || _thread == null) return;
    _thread = null;
    _contextNotice = null;
    _draftScopeRevision += 1;
    await _restoreNewChatModel();
    notifyListeners();
  }

  Future<bool> newConversationOnServer(String id) async {
    if (!await switchServerProfile(id, preserveConversation: true))
      return false;
    await newConversation();
    return _thread == null && activeProfileId == id;
  }

  Future<void> _restoreNewChatModel() async {
    _selectedModel = null;
    _selectedModelDetails = null;
    final last =
        _settingsStore.defaultModel(activeProfileId) ??
        _settingsStore.lastSelectedModel(activeProfileId);
    final next = _models.any((m) => m.name == last)
        ? last
        : (_models.isEmpty ? null : _models.first.name);
    if (isConnected && next != null) await selectModel(next);
  }

  Future<void> discardCurrentDraft() async {
    if (_profileChangesBlocked) return;
    final documents = List.of(_draft.documents);
    await _discardPendingImage();
    _drafts.remove(draftKey);
    await flushDrafts();
    if (_draftPersistenceError == null) {
      for (final document in documents) {
        if (!await _conversations.isImageReferenceInUse(document.reference)) {
          try {
            await _images.deleteReference(document.reference);
          } on Object {
            _errorMessage =
                'Draft discarded, but an unused file could not be removed.';
          }
        }
      }
    }
    _draftScopeRevision += 1;
    notifyListeners();
  }

  Future<void> openConversation(String id) async {
    if (_profileChangesBlocked || _thread?.conversation.id == id) return;
    final matches = _history.where((chat) => chat.id == id);
    if (matches.isEmpty) return;
    final profileId = matches.first.serverProfileId;
    _conversationMutationBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _openConversationInternal(
        id,
        profileId: profileId,
        advanceDraftScope: true,
      );
      _selectedModel = null;
      _selectedModelDetails = null;
      if (!conversationConnected) {
        final profile = _profileById(profileId);
        if (profile == null) {
          _errorMessage = 'This chat’s server is unavailable.';
          return;
        }
        try {
          final probe = await _probeServerProfile(profile);
          if (_shutdownFuture != null) return;
          await _settingsStore.setActiveProfile(profileId);
          await _commitServerProbe(probe, preserveConversation: true);
          return;
        } on Object catch (error) {
          _errorMessage =
              'Could not connect to ${profile.name}. ${_friendlyError(error)}';
          return;
        }
      }
      if (conversationConnected) {
        final stored = _thread!.conversation.selectedModel;
        if (_models.any((model) => model.name == stored)) {
          if (_isStreaming) {
            _selectedModel = stored;
            _selectedModelDetails = _modelDetails['$profileId:$stored'];
          } else {
            await selectModel(stored);
          }
        }
      }
    } on Object catch (error) {
      _errorMessage = 'Chat could not be opened: ${_friendlyError(error)}';
    } finally {
      _conversationMutationBusy = false;
      notifyListeners();
    }
  }

  Future<bool> connectConversation() =>
      switchServerProfile(conversationProfile.id, preserveConversation: true);
  Future<bool> renameConversation(String id, String title) =>
      _organize(() => _conversations.rename(id, title));
  Future<bool> pinConversation(String id, bool value) =>
      _organize(() => _conversations.setPinned(id, value));
  Future<bool> archiveConversation(String id, bool value) =>
      _organize(() => _conversations.setArchived(id, value));

  Future<String> conversationMarkdown(String id) async {
    final chat = _history.where((item) => item.id == id).firstOrNull;
    if (chat == null)
      throw const FormatException('Conversation no longer exists.');
    return ChatBackup(_conversations).exportConversationMarkdown(
      serverProfileId: chat.serverProfileId,
      conversationId: id,
    );
  }

  Future<String> exportBackup() async {
    if (!canChangeContext) throw StateError('Finish the current action first.');
    _conversationMutationBusy = true;
    notifyListeners();
    try {
      return await ChatBackup(_conversations).exportJson(
        serverProfiles: [
          for (final profile in profiles)
            BackupServerProfile(
              id: profile.id,
              name: profile.name,
              protocol: profile.protocol.name,
              baseUrl: profile.baseUrl,
            ),
        ],
        readAttachment: (reference) async =>
            base64Decode(await _images.readAsBase64(reference)),
      );
    } finally {
      _conversationMutationBusy = false;
      notifyListeners();
    }
  }

  Future<int> importBackup(String json) async {
    if (!canChangeContext) throw StateError('Finish the current action first.');
    _conversationMutationBusy = true;
    notifyListeners();
    final createdProfiles = <String>[];
    var imported = false;
    try {
      final backup = ChatBackup(_conversations);
      final inspection = backup.inspectJson(json);
      final mappings = await _mapBackupProfiles(inspection, createdProfiles);
      final result = await backup.importJson(
        json: json,
        serverProfileMappings: mappings,
        allocateId: _idFactory,
        writeAttachment: (attachment, conversationId) => _images.writeBytes(
          conversationId: conversationId,
          bytes: attachment.bytes,
          sourceName: attachment.sourceName,
        ),
        deleteAttachment: _images.deleteReference,
      );
      imported = true;
      await _reloadHistory();
      return result.conversations;
    } finally {
      try {
        if (!imported) {
          for (final id in createdProfiles) {
            await _settingsStore.deleteProfile(id);
          }
        }
      } finally {
        _conversationMutationBusy = false;
        notifyListeners();
      }
    }
  }

  Future<Map<String, String>> _syncLocalVersions() async {
    final versions = <String, String>{};
    for (final chat in await _conversations.listAllConversations(
      includeEmpty: true,
    )) {
      final thread = await _conversations.openConversation(
        serverProfileId: chat.serverProfileId,
        id: chat.id,
      );
      if (thread == null) continue;
      final profile = _profileById(chat.serverProfileId);
      final value = [
        chat.id,
        profile?.protocol.name,
        profile?.baseUrl,
        profile?.name,
        chat.title,
        chat.selectedModel,
        chat.systemPrompt,
        chat.isPinned,
        chat.isArchived,
        chat.isRenamed,
        chat.generationOptions.toOllamaJson(),
        chat.createdAt.toUtc().toIso8601String(),
        chat.updatedAt.toUtc().toIso8601String(),
        for (final message in thread.messages)
          [
            message.id,
            message.position,
            message.role.name,
            message.status.name,
            message.content,
            message.reasoning,
            message.providerTranscriptJson,
            message.imageReferences,
            message.documents.map((d) => d.toJson()).toList(),
            message.toolCalls.map((c) => c.toJson()).toList(),
            message.toolResults.map((r) => r.toJson()).toList(),
            message.createdAt.toUtc().toIso8601String(),
            message.updatedAt.toUtc().toIso8601String(),
          ],
      ];
      versions[chat.id] = sha256
          .convert(utf8.encode(jsonEncode(value)))
          .toString();
    }
    return versions;
  }

  Future<String> _exportSyncChat(String id) async {
    final chat = (await _conversations.listAllConversations(includeEmpty: true))
        .firstWhere((chat) => chat.id == id);
    final profile = _profileById(chat.serverProfileId);
    if (profile == null)
      throw StateError('The chat server profile is missing.');
    final json = await ChatBackup(_conversations).exportJson(
      conversationIds: {id},
      serverProfiles: [
        BackupServerProfile(
          id: profile.id,
          name: profile.name,
          protocol: profile.protocol.name,
          baseUrl: profile.baseUrl,
        ),
      ],
      readAttachment: (reference) async =>
          base64Decode(await _images.readAsBase64(reference)),
    );
    final value = jsonDecode(json) as Map<String, dynamic>;
    // The same committed snapshot must produce the same bytes on retries.
    value['exportedAt'] = chat.updatedAt.toUtc().toIso8601String();
    return jsonEncode(value);
  }

  Future<void> _applySyncChange(ChatSyncChange change) async {
    if (await _conversations.hasSyncReceipt(change.token)) return;
    if (isConversationRunning(change.id) ||
        (_queues[change.id]?.isNotEmpty ?? false)) {
      throw StateError(
        'This chat has pending messages. Finish or remove them before syncing.',
      );
    }
    if (change.deleted) {
      final draft = _drafts[change.id];
      if (draft != null &&
          (draft.text.isNotEmpty ||
              draft.images.isNotEmpty ||
              draft.documents.isNotEmpty)) {
        final chat = _history.where((chat) => chat.id == change.id).firstOrNull;
        throw StateError(
          '“${chat?.title ?? 'A deleted chat'}” still has a local draft. Send or discard it before syncing its deletion.',
        );
      }
      await _draftWriteTail;
      await _conversations.applySyncDeletion(
        conversationId: change.id,
        receiptToken: change.token,
      );
      _drafts.remove(change.id);
      if (conversation?.id == change.id) {
        _thread = null;
        _draftScopeRevision++;
        _contextNotice = null;
      }
      try {
        await _images.deleteConversation(change.id);
      } on Object {
        _errorMessage = 'The synced deletion succeeded, but an unused attachment could not be removed.';
      }
      await _reloadHistory();
      return;
    }
    final json = change.json;
    if (json == null)
      throw const FormatException('A synced chat has no content.');
    final backup = ChatBackup(_conversations);
    final inspection = backup.inspectJson(json);
    final createdProfiles = <String>[];
    var applied = false;
    try {
      final mappings = await _mapBackupProfiles(inspection, createdProfiles);
      final result = await backup.applySyncedJson(
        json: json,
        targetConversationId: change.id,
        receiptToken: change.token,
        asConflictCopy: change.conflict,
        serverProfileMappings: mappings,
        allocateId: _idFactory,
        writeAttachment: (attachment, conversationId) => _images.writeBytes(
          conversationId: conversationId,
          bytes: attachment.bytes,
          sourceName: attachment.sourceName,
        ),
        deleteAttachment: _images.deleteReference,
      );
      applied = true;
      if (result.cleanupWarning != null) _errorMessage = result.cleanupWarning;
      await _reloadHistory();
      if (conversation?.id == change.id) {
        final chat = _history.where((chat) => chat.id == change.id).firstOrNull;
        if (chat != null) {
          _thread = await _conversations.openConversation(
            serverProfileId: chat.serverProfileId,
            id: chat.id,
          );
          _selectedModel =
              chat.serverProfileId == activeProfileId &&
                  _models.any((m) => m.name == chat.selectedModel)
              ? chat.selectedModel
              : null;
          _selectedModelDetails = _selectedModel == null
              ? null
              : detailsForModel(_selectedModel!);
          _contextNotice = null;
        }
      }
    } finally {
      if (!applied) {
        for (final id in createdProfiles) {
          await _settingsStore.deleteProfile(id);
        }
      }
    }
  }

  Future<Map<String, String>> _mapBackupProfiles(
    ChatBackupInspection inspection,
    List<String> createdProfiles,
  ) async {
    final mappings = <String, String>{};
    for (final source in inspection.profiles) {
      final protocol = ServerProtocol.values
          .where((p) => p.name == source.protocol)
          .firstOrNull;
      if (protocol == null)
        throw const FormatException('Unsupported backup server protocol.');
      final url = _canonicalServerBaseUrl(protocol, source.baseUrl);
      final existing = profiles
          .where(
            (p) =>
                p.protocol == protocol &&
                _canonicalServerBaseUrl(p.protocol, p.baseUrl) == url,
          )
          .firstOrNull;
      if (existing != null) {
        mappings[source.id] = existing.id;
      } else {
        final id = _idFactory();
        await _settingsStore.upsertProfile(
          ServerProfile(
            id: id,
            name: source.name,
            protocol: protocol,
            baseUrl: url,
          ),
        );
        mappings[source.id] = id;
        createdProfiles.add(id);
      }
    }
    return mappings;
  }

  Future<bool> _organize(Future<void> Function() action) async {
    if (_profileChangesBlocked) return false;
    _conversationMutationBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await action();
      await _reloadHistory();
      final current = _thread;
      if (current != null) {
        final updated = _history.where(
          (chat) => chat.id == current.conversation.id,
        );
        if (updated.isNotEmpty) {
          _thread = ConversationThread(
            conversation: updated.first,
            messages: current.messages,
          );
        }
      }
      return true;
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
      return false;
    } finally {
      _conversationMutationBusy = false;
      notifyListeners();
    }
  }

  Future<bool> deleteConversation(String id) async {
    if (_profileChangesBlocked) return false;
    final matches = _history.where((chat) => chat.id == id);
    if (matches.isEmpty) return false;
    _conversationMutationBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      final run = _runs[id];
      if (run != null) await _stopRun(run);
      await _draftWriteTail;
      await _conversations.deleteConversation(
        serverProfileId: matches.first.serverProfileId,
        id: id,
      );
      _drafts.remove(id);
      _queues.remove(id);
      _queuePausedIds.remove(id);
      _runErrors.remove(id);
      if (_thread?.conversation.id == id) {
        _thread = null;
        _draftScopeRevision += 1;
        await _restoreNewChatModel();
      }
      await _reloadHistory();
      try {
        await _images.deleteConversation(id);
      } on Object {
        _errorMessage = 'Chat deleted, but an image file could not be removed.';
      }
      return true;
    } on Object catch (error) {
      _errorMessage = 'Chat could not be deleted: ${_friendlyError(error)}';
      return false;
    } finally {
      _conversationMutationBusy = false;
      notifyListeners();
    }
  }

  Future<bool> deleteAllConversations() async {
    if (_profileChangesBlocked) return false;
    _conversationMutationBusy = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await Future.wait(_runs.values.toList().map(_stopRun));
      final all = await _conversations.listAllConversations(includeEmpty: true);
      final imageIds = <String>{
        ...all.map((c) => c.id),
        ..._drafts.values.map((d) => d.reservedId).whereType<String>(),
      };
      await _draftWriteTail;
      await _conversations.deleteAllConversations();
      _thread = null;
      _drafts.clear();
      _queues.clear();
      _queuePausedIds.clear();
      _runErrors.clear();
      _draftPersistenceError = null;
      _history = const [];
      _syncRevision++;
      _draftScopeRevision += 1;
      await _restoreNewChatModel();
      var failed = 0;
      for (final id in imageIds) {
        try {
          await _images.deleteConversation(id);
        } on Object {
          failed++;
        }
      }
      _errorMessage = failed == 0
          ? null
          : 'All chats deleted; image cleanup failed for $failed chat folders.';
      return true;
    } on Object catch (error) {
      _errorMessage = 'Chats could not be deleted: ${_friendlyError(error)}';
      return false;
    } finally {
      _conversationMutationBusy = false;
      notifyListeners();
    }
  }

  ChatDefaults get chatDefaults => _settingsStore.chatDefaults;
  List<PromptPreset> get promptPresets => _settingsStore.promptPresets;

  Future<bool> savePromptPreset({
    String? id,
    required String name,
    required String systemPrompt,
    required GenerationOptions generationOptions,
  }) async {
    try {
      final preset = PromptPreset(
        id: id ?? _idFactory(),
        name: name,
        systemPrompt: systemPrompt,
        generationOptions: generationOptions,
      );
      await _settingsStore.savePromptPresets([
        for (final existing in promptPresets)
          if (existing.id != preset.id) existing,
        preset,
      ]);
      _errorMessage = null;
      notifyListeners();
      return true;
    } on Object catch (error) {
      _errorMessage = 'Preset could not be saved: ${_friendlyError(error)}';
      notifyListeners();
      return false;
    }
  }

  Future<bool> deletePromptPreset(String id) async {
    try {
      await _settingsStore.savePromptPresets([
        for (final preset in promptPresets)
          if (preset.id != id) preset,
      ]);
      _errorMessage = null;
      notifyListeners();
      return true;
    } on Object catch (error) {
      _errorMessage = 'Preset could not be deleted: ${_friendlyError(error)}';
      notifyListeners();
      return false;
    }
  }

  Future<bool> applyPromptPreset(String id) async {
    final preset = promptPresets.where((item) => item.id == id).firstOrNull;
    if (preset == null) return false;
    return updateConversationSettings(
      systemPrompt: preset.systemPrompt,
      generationOptions: preset.generationOptions,
    );
  }

  String? defaultModelFor(String profileId) =>
      _settingsStore.defaultModel(profileId);

  /// Query a settings page's server without replacing the open chat's client.
  Future<List<ChatModelOption>> loadModelsForProfile(String id) async {
    if (!canChangeContext) throw StateError('Wait for the current action.');
    final profile = _profileById(id);
    if (profile == null) throw StateError('This server is unavailable.');
    _profileMutationBusy = true;
    _modelManagementBusy = true;
    _modelManagementProfileId = id;
    _modelManagementError = null;
    _modelManagementStatus = 'Loading models…';
    notifyListeners();
    try {
      final probe = await _probeServerProfile(profile);
      _setProfileModels(id, probe.models);
      if (probe.openAiCompatible != null) {
        for (final model in probe.models) {
          _modelDetails['$id:${model.name}'] = _compatibleDetailsForProfile(
            id,
            model.name,
            probe.openAiCompatible,
          );
        }
      } else {
        final client = probe.ollama!;
        for (final model in probe.models) {
          final key = '$id:${model.name}';
          if (_modelDetails.containsKey(key)) continue;
          try {
            _modelDetails[key] = await client.showModel(model.name);
          } on Object {
            // An unavailable detail response must not hide installed models.
          }
        }
      }
      _modelManagementStatus = null;
      return probe.models;
    } on Object catch (error) {
      _modelManagementError = _friendlyError(error);
      _modelManagementStatus = null;
      rethrow;
    } finally {
      _modelManagementBusy = false;
      _profileMutationBusy = false;
      notifyListeners();
    }
  }

  Future<bool> updateChatDefaults({
    required String systemPrompt,
    required GenerationOptions generationOptions,
  }) async {
    final prompt = systemPrompt.trim();
    if (utf8.encode(prompt).length > maxMessageTextBytes) {
      _errorMessage = 'Instructions can be at most 64 KB.';
      notifyListeners();
      return false;
    }
    try {
      generationOptions.validate();
      if (generationOptions.maxTokens != null &&
          generationOptions.maxTokens! < 1) {
        throw const FormatException(
          'Default max tokens must be positive or blank.',
        );
      }
      await _settingsStore.setChatDefaults(
        ChatDefaults(
          systemPrompt: prompt,
          generationOptions: generationOptions,
        ),
      );
      _errorMessage = null;
      notifyListeners();
      return true;
    } on Object catch (error) {
      _errorMessage = 'Defaults could not be saved: ${_friendlyError(error)}';
      notifyListeners();
      return false;
    }
  }

  Future<bool> setDefaultModel(String? model) async {
    if (model != null && !_models.any((item) => item.name == model)) {
      return false;
    }
    return setDefaultModelFor(activeProfileId, model);
  }

  Future<bool> setDefaultModelFor(String profileId, String? model) async {
    if (_profileById(profileId) == null) return false;
    try {
      await _settingsStore.setDefaultModel(profileId, model);
      if (profileId == activeProfileId && _thread == null && canChangeContext)
        await _restoreNewChatModel();
      _errorMessage = null;
      notifyListeners();
      return true;
    } on Object catch (error) {
      _errorMessage =
          'Default model could not be saved: ${_friendlyError(error)}';
      notifyListeners();
      return false;
    }
  }

  Future<bool> updateSystemPrompt(String value) => updateConversationSettings(
    systemPrompt: value,
    generationOptions: generationOptions,
  );

  Future<bool> updateGenerationOptions(GenerationOptions value) =>
      updateConversationSettings(
        systemPrompt: systemPrompt,
        generationOptions: value,
      );

  Future<bool> updateConversationSettings({
    required String systemPrompt,
    required GenerationOptions generationOptions,
  }) async {
    final current = _thread?.conversation;
    final model = current?.selectedModel;
    if (_profileChangesBlocked || _isStreaming || queuedPrompts.isNotEmpty) {
      return false;
    }
    final prompt = systemPrompt.trim();
    if (prompt.length > maxMessageTextBytes ||
        utf8.encode(prompt).length > maxMessageTextBytes) {
      _errorMessage = 'The system prompt can be at most 64 KB.';
      notifyListeners();
      return false;
    }
    try {
      generationOptions.validate();
      if (current == null || model == null) {
        _draft.systemPrompt = prompt;
        _draft.options = generationOptions;
        await flushDrafts();
        notifyListeners();
        return true;
      }
      final updatedAt = DateTime.now().toUtc();
      await _conversations.updateConversationSettings(
        id: current.id,
        selectedModel: model,
        systemPrompt: prompt,
        generationOptions: generationOptions,
        now: updatedAt,
      );
      _thread = ConversationThread(
        conversation: _copyConversation(
          current,
          selectedModel: model,
          systemPrompt: prompt,
          generationOptions: generationOptions,
          updatedAt: updatedAt,
        ),
        messages: messages,
      );
      await _reloadHistory();
      _errorMessage = null;
      notifyListeners();
      return true;
    } on Object catch (error) {
      _errorMessage = _friendlyError(error);
      notifyListeners();
      return false;
    }
  }

  Future<void> setThemePreference(ThemePreference value) async {
    await _settingsStore.setTheme(value);
    _settings = LocalSettings(
      baseUrl: baseUrl,
      serverProtocol: serverProtocol,
      insecureLanAcknowledged: insecureLanAcknowledged,
      theme: value,
      webAgentEnabled: webAgentEnabled,
    );
    notifyListeners();
  }

  Future<void> removeServerApiKey({String? profileId}) async {
    final profile = _profileById(profileId ?? activeProfileId);
    if (_profileChangesBlocked ||
        profile?.protocol != ServerProtocol.openAiCompatible) {
      return;
    }
    final secret = _serverApiKeySecret(profile!.protocol, profile.baseUrl);
    await _secrets.delete(secret);
    _storedServerApiKeySecrets.remove(secret);
    if (_serverSecretForProfile(activeProfile) == secret) {
      _serverApiKey = null;
      _openAiCompatible = null;
      _models = const [];
      _selectedModel = null;
      _selectedModelDetails = null;
      _connectionState = ServerConnectionState.disconnected;
    }
    notifyListeners();
  }

  Future<void> saveWebApiKey(String value) async {
    final key = value.trim();
    if (key.isEmpty) {
      await _secrets.delete(_webApiKeySecret);
      _webApiKey = null;
      if (webAgentEnabled) await setWebAgentEnabled(false);
    } else {
      await _secrets.write(_webApiKeySecret, key);
      _webApiKey = key;
    }
    notifyListeners();
  }

  Future<void> acknowledgeWebDisclosure() async {
    await _secrets.write(_webDisclosureSecret, 'true');
    _webDisclosureAcknowledged = true;
    notifyListeners();
  }

  Future<bool> setWebAgentEnabled(bool value) async {
    if (value && _modelLoading) return false;
    if (value && (!_webDisclosureAcknowledged || !hasWebApiKey)) {
      return false;
    }
    await _settingsStore.setWebAgentEnabled(value);
    _settings = LocalSettings(
      baseUrl: baseUrl,
      serverProtocol: serverProtocol,
      insecureLanAcknowledged: insecureLanAcknowledged,
      theme: themePreference,
      webAgentEnabled: value,
    );
    notifyListeners();
    return true;
  }

  Future<void> pickImage({bool camera = false}) async {
    if (!canQueueOrSend || !supportsImages) return;
    if (_draft.images.length >= maxRequestImages) {
      _errorMessage = 'Attach up to eight images per message.';
      notifyListeners();
      return;
    }
    _conversationMutationBusy = true;
    notifyListeners();
    String? added;
    try {
      final draft = _draft;
      final key = draftKey;
      final id = conversation?.id ?? (draft.reservedId ??= _idFactory());
      added = await _images.pickAndCopy(conversationId: id, camera: camera);
      if (added == null) return;
      if (draftKey != key) {
        await _images.deleteReference(added);
        return;
      }
      final bytes = await _images.sizeInBytes(added);
      if (bytes <= 0 || bytes > maxImageBytes) {
        throw const ChatRequestLimitException(
          'An image must be between 1 byte and 8 MB.',
        );
      }
      var total = bytes;
      for (final reference in draft.images) {
        total += await _images.sizeInBytes(reference);
      }
      if (total > maxRequestImageBytes) {
        throw const ChatRequestLimitException(
          'Images in one message can total at most 24 MB.',
        );
      }
      draft.images = [...draft.images, added];
      added = null;
      await flushDrafts();
      _errorMessage = null;
    } on Object catch (error) {
      if (added != null) await _deleteUnusedAttachment(added);
      _errorMessage = _friendlyError(error);
    } finally {
      _conversationMutationBusy = false;
      notifyListeners();
    }
  }

  Future<void> pickDocument() async {
    if (!canChangeContext) return;
    if (_draft.documents.length >= DocumentAttachment.maxPerMessage) {
      _errorMessage = 'Attach up to four documents per message.';
      notifyListeners();
      return;
    }
    _conversationMutationBusy = true;
    notifyListeners();
    try {
      final draft = _draft;
      final key = draftKey;
      final picked = await _documentReader.pick();
      if (picked == null || draftKey != key) return;
      final conversationId =
          _thread?.conversation.id ?? (draft.reservedId ??= _idFactory());
      final reference = await _images.writeBytes(
        conversationId: conversationId,
        bytes: picked.bytes,
        sourceName: picked.name,
      );
      draft.documents = [
        ...draft.documents,
        DocumentAttachment(
          id: _idFactory(),
          name: picked.name,
          mimeType: picked.mimeType,
          reference: reference,
          text: picked.text,
        ),
      ];
      await flushDrafts();
      _errorMessage = null;
    } on Object catch (error) {
      _errorMessage =
          'Document could not be attached: ${_friendlyError(error)}';
    } finally {
      _conversationMutationBusy = false;
      notifyListeners();
    }
  }

  Future<void> removePendingDocument(String id) async {
    if (!canChangeContext) return;
    final document = _draft.documents
        .where((document) => document.id == id)
        .firstOrNull;
    if (document == null) return;
    _draft.documents = [
      for (final item in _draft.documents)
        if (item.id != id) item,
    ];
    await flushDrafts();
    if (_draftPersistenceError == null &&
        !await _conversations.isImageReferenceInUse(document.reference)) {
      try {
        await _images.deleteReference(document.reference);
      } on Object catch (error) {
        _errorMessage =
            'The unused file could not be removed: ${_friendlyError(error)}';
      }
    }
    notifyListeners();
  }

  Future<void> removePendingImage([String? reference]) =>
      _conversationMutationBusy
      ? Future<void>.value()
      : _discardPendingImage(reference);

  _RunConfiguration _captureRunConfiguration() => _RunConfiguration(
    profile: conversationProfile,
    ollama: _ollama,
    compatible: _openAiCompatible,
    thinking: _selectedModelDetails?.supportsThinking == true,
    webEnabled: webAgentEffective,
    webKey: _webApiKey,
  );

  Future<void> _reloadQueues() async {
    final pending = await _conversations.loadQueuedPrompts();
    _queues.clear();
    for (final prompt in pending) {
      (_queues[prompt.conversationId] ??= []).add(prompt);
    }
  }

  Future<bool> send(String value) async {
    final text = value.trim();
    final submittedDraft = _draft;
    if ((text.isEmpty &&
            submittedDraft.images.isEmpty &&
            submittedDraft.documents.isEmpty) ||
        !canQueueOrSend)
      return false;
    if (utf8.encode(text).length > maxMessageTextBytes) {
      _errorMessage = 'A message can be at most 64 KB.';
      notifyListeners();
      return false;
    }
    if (submittedDraft.images.isNotEmpty && !supportsImages) {
      _errorMessage = 'The selected model does not support images.';
      notifyListeners();
      return false;
    }
    final configuration = _captureRunConfiguration();
    _isSubmitting = true;
    final submission = Completer<void>();
    _submissionCompleter = submission;
    _errorMessage = null;
    notifyListeners();
    String? acceptedConversation;
    var alreadyPending = false;
    try {
      await flushDrafts();
      final thread = await _ensureConversation();
      if (thread == null) return false;
      final id = thread.conversation.id;
      alreadyPending =
          isConversationRunning(id) || (_queues[id]?.isNotEmpty ?? false);
      if (!alreadyPending) _queuePausedIds.remove(id);
      final prompt = QueuedPrompt(
        id: _idFactory(),
        conversationId: id,
        text: text,
        imageReferences: List.of(submittedDraft.images),
        documents: List.of(submittedDraft.documents),
        createdAt: DateTime.now().toUtc(),
      );
      await _conversations.enqueuePrompt(prompt);
      acceptedConversation = id;
      submittedDraft.images = [];
      submittedDraft.documents = [];
      if (submittedDraft.text.trim() == text) submittedDraft.text = '';
      await flushDrafts();
      await _reloadQueues();
      await _reloadHistory();
    } on Object catch (error) {
      _errorMessage =
          'The message could not be queued: ${_friendlyError(error)}';
    } finally {
      if (identical(_submissionCompleter, submission)) {
        _isSubmitting = false;
        _submissionCompleter = null;
      }
      submission.complete();
      notifyListeners();
    }
    if (acceptedConversation == null) return false;
    final id = acceptedConversation;
    if (!isConversationRunning(id) && !_queuePausedIds.contains(id)) {
      await _drainQueue(
        id,
        configuration,
        restoreOnStartupFailure: alreadyPending,
      );
    }
    return true;
  }

  Future<void> _drainQueue(
    String id,
    _RunConfiguration configuration, {
    bool restoreOnStartupFailure = true,
  }) {
    final drain = _drainQueueInOrder(
      id,
      configuration,
      restoreOnStartupFailure: restoreOnStartupFailure,
    );
    _queueDrains.add(drain);
    return drain.whenComplete(() => _queueDrains.remove(drain));
  }

  Future<void> _drainQueueInOrder(
    String id,
    _RunConfiguration configuration, {
    required bool restoreOnStartupFailure,
  }) async {
    if (_shutdownFuture != null ||
        isConversationRunning(id) ||
        _queuePausedIds.contains(id))
      return;
    _queueStartingIds.add(id);
    notifyListeners();
    QueuedPromptClaim? claim;
    var ownsStart = true;
    try {
      // Jaz's queue.go uses the same claim-before-dispatch transition. The
      // SQLite transaction also creates our recoverable transcript placeholders.
      claim = await _conversations.claimQueuedPrompt(
        id,
        userMessageId: _idFactory(),
        assistantMessageId: _idFactory(),
      );
      await _reloadQueues();
      if (claim == null) return;
      if (_queuePausedIds.contains(id) || _shutdownFuture != null) {
        await _conversations.restoreQueuedPrompt(claim);
        await _reloadQueues();
        return;
      }
      final thread = await _conversations.openConversation(
        serverProfileId: configuration.profile.id,
        id: id,
      );
      if (thread == null)
        throw StateError('The queued conversation is unavailable.');
      await _reloadHistory();
      if (_queuePausedIds.contains(id) || _shutdownFuture != null) {
        await _conversations.restoreQueuedPrompt(claim);
        await _reloadQueues();
        return;
      }
      if (conversation?.id == id) _thread = thread;
      _queueStartingIds.remove(id);
      ownsStart = false;
      await _startAssistantResponse(
        persistedAssistant: claim.assistantMessage,
        sourceThread: thread,
        configuration: configuration,
        claim: claim,
        restoreOnStartupFailure: restoreOnStartupFailure,
      );
    } on Object catch (error) {
      _queuePausedIds.add(id);
      _runErrors[id] = 'Queue paused: ${_friendlyError(error)}';
      if (claim != null && !_runs.containsKey(id)) {
        try {
          await _conversations.restoreQueuedPrompt(claim);
          await _reloadQueues();
          await _refreshVisibleConversation(id, configuration.profile.id);
        } on Object catch (restoreError) {
          _runErrors[id] =
              'Queue paused; the submitted message remains in history: '
              '${_friendlyError(restoreError)}';
        }
      }
    } finally {
      if (ownsStart) _queueStartingIds.remove(id);
      notifyListeners();
    }
  }

  Future<void> resumeQueue() async {
    final id = conversation?.id;
    if (id == null || !canQueueOrSend || isConversationRunning(id)) return;
    _queuePausedIds.remove(id);
    _runErrors.remove(id);
    await _drainQueue(id, _captureRunConfiguration());
  }

  Future<void> editQueuedPrompt(String id, String text) => _mutateQueue(
    (conversationId) => _conversations.updateQueuedPromptText(
      conversationId: conversationId,
      id: id,
      text: text,
    ),
  );

  Future<void> reorderQueuedPrompts(List<String> ids) => _mutateQueue(
    (conversationId) => _conversations.reorderQueuedPrompts(
      conversationId: conversationId,
      ids: ids,
    ),
  );

  Future<void> removeQueuedPrompt(String id) async {
    final prompt = queuedPrompts.where((item) => item.id == id).firstOrNull;
    await _mutateQueue(
      (conversationId) => _conversations.deleteQueuedPrompt(
        conversationId: conversationId,
        id: id,
      ),
    );
    if (prompt != null &&
        !(_queues[prompt.conversationId] ?? []).any((item) => item.id == id)) {
      for (final reference in [
        ...prompt.imageReferences,
        ...prompt.documents.map((document) => document.reference),
      ]) {
        await _deleteUnusedAttachment(reference);
      }
    }
  }

  Future<void> _mutateQueue(Future<void> Function(String) mutate) async {
    final id = conversation?.id;
    if (id == null || _shutdownFuture != null) return;
    try {
      await mutate(id);
      await _reloadQueues();
      if (_queues[id]?.isEmpty ?? true) _queuePausedIds.remove(id);
      _errorMessage = null;
    } on Object catch (error) {
      _errorMessage = 'Queue could not be updated: ${_friendlyError(error)}';
      await _reloadQueues();
    }
    notifyListeners();
  }

  Future<void> _refreshVisibleConversation(String id, String profileId) async {
    if (conversation?.id != id) return;
    final updated = await _conversations.openConversation(
      serverProfileId: profileId,
      id: id,
    );
    if (conversation?.id == id && updated != null) _thread = updated;
  }

  Future<void> retryAssistant(String id) async {
    if (_isStreaming ||
        _isSubmitting ||
        _modelLoading ||
        _profileMutationBusy ||
        _conversationMutationBusy ||
        !conversationConnected ||
        _selectedModel == null) {
      return;
    }
    final index = messages.indexWhere((message) => message.id == id);
    if (index < 0 || messages[index].role != MessageRole.assistant) return;
    final latestAssistant = messages.lastIndexWhere(
      (message) => message.role == MessageRole.assistant,
    );
    if (index != latestAssistant ||
        messages[index].status == MessageStatus.complete) {
      return;
    }
    _isSubmitting = true;
    final submission = Completer<void>();
    _submissionCompleter = submission;
    notifyListeners();
    try {
      final target = messages[index];
      final timestamp = DateTime.now().toUtc();
      final replacement = Message(
        id: _idFactory(),
        conversationId: target.conversationId,
        position: target.position,
        role: MessageRole.assistant,
        status: MessageStatus.streaming,
        content: '',
        createdAt: timestamp,
        updatedAt: timestamp,
      );
      await _conversations.replaceConversationTail(
        conversationId: target.conversationId,
        fromPosition: target.position,
        replacement: replacement,
      );
      _replaceMessages(<Message>[
        for (final message in messages)
          if (message.position < target.position) message,
        replacement,
      ]);
      notifyListeners();
      await _startAssistantResponse(persistedAssistant: replacement);
    } on Object catch (error) {
      _errorMessage =
          'The response could not be retried: ${_friendlyError(error)}';
      notifyListeners();
    } finally {
      if (identical(_submissionCompleter, submission) && _isSubmitting) {
        _isSubmitting = false;
        notifyListeners();
      }
      if (!submission.isCompleted) submission.complete();
      if (identical(_submissionCompleter, submission)) {
        _submissionCompleter = null;
      }
    }
  }

  Future<bool> editAndResend(String id, String text) =>
      _reviseConversation(id, editedText: text.trim());

  Future<bool> regenerateAssistant(String id) => _reviseConversation(id);

  Future<bool> _reviseConversation(String id, {String? editedText}) async {
    if (!canSend) return false;
    final index = messages.indexWhere((message) => message.id == id);
    if (index < 0) return false;
    final target = messages[index];
    final editing = editedText != null;
    if ((editing && target.role != MessageRole.user) ||
        (!editing && target.role != MessageRole.assistant))
      return false;
    if (editing &&
        ((editedText.isEmpty &&
                target.imageReferences.isEmpty &&
                target.documents.isEmpty) ||
            utf8.encode(editedText).length > maxMessageTextBytes)) {
      _errorMessage =
          'Enter a message or keep an attachment, up to 64 KB of text.';
      notifyListeners();
      return false;
    }
    final current = conversation!;
    final removedImages = messages
        .skip(index)
        .expand(
          (m) => [...m.imageReferences, ...m.documents.map((d) => d.reference)],
        )
        .toSet();
    final replacement = editing
        ? target.copyWith(
            content: editedText,
            updatedAt: DateTime.now().toUtc(),
          )
        : null;
    _isSubmitting = true;
    final submission = Completer<void>();
    _submissionCompleter = submission;
    _errorMessage = null;
    notifyListeners();
    var saved = false;
    String? cleanupWarning;
    try {
      await _conversations.replaceConversationTail(
        conversationId: current.id,
        fromPosition: target.position,
        replacement: replacement,
      );
      saved = true;
      for (final reference in removedImages) {
        if (!_drafts.values.any(
              (draft) =>
                  draft.images.contains(reference) ||
                  draft.documents.any((d) => d.reference == reference),
            ) &&
            !await _conversations.isImageReferenceInUse(reference)) {
          try {
            await _images.deleteReference(reference);
          } on Object {
            cleanupWarning = 'The chat was updated, but an unused attachment could not be removed.';
          }
        }
      }
      _thread = await _conversations.openConversation(
        serverProfileId: current.serverProfileId,
        id: current.id,
      );
      await _reloadHistory();
      notifyListeners();
      await _startAssistantResponse();
    } on Object catch (error) {
      _errorMessage =
          'The response could not be restarted: ${_friendlyError(error)}';
      notifyListeners();
    } finally {
      if (cleanupWarning != null) {
        _errorMessage = [
          _errorMessage,
          cleanupWarning,
        ].whereType<String>().join('\n');
      }
      _isSubmitting = false;
      if (!submission.isCompleted) submission.complete();
      if (identical(_submissionCompleter, submission))
        _submissionCompleter = null;
      notifyListeners();
    }
    return saved;
  }

  Future<void> stop() async {
    final id = conversation?.id;
    if (id == null) return;
    _queuePausedIds.add(id);
    final run = _runs[id];
    if (run != null) await _stopRun(run);
  }

  Future<void> _stopRun(_ChatRun run, {String? reason}) async {
    run.stopRequested = true;
    _queuePausedIds.add(run.conversationId);
    if (reason != null) _runErrors[run.conversationId] = reason;
    await run.chat?.cancel();
    await run.agent?.cancel();
    await run.iterator?.cancel();
    await _finishRun(run, MessageStatus.interrupted, error: reason);
    await run.finished.future;
  }

  void clearError() {
    _errorMessage = null;
    _draftPersistenceError = null;
    _runErrors.remove(conversation?.id);
    notifyListeners();
  }

  Future<void> _startAssistantResponse({
    Message? persistedAssistant,
    ConversationThread? sourceThread,
    _RunConfiguration? configuration,
    QueuedPromptClaim? claim,
    bool restoreOnStartupFailure = false,
  }) async {
    var thread = sourceThread ?? _thread;
    if (thread == null) return;
    final config = configuration ?? _captureRunConfiguration();
    if (config.ollama == null && config.compatible == null) return;
    final assistant =
        persistedAssistant ??
        await _conversations.appendMessage(
          id: _idFactory(),
          conversationId: thread.conversation.id,
          role: MessageRole.assistant,
          status: MessageStatus.streaming,
          content: '',
        );
    if (persistedAssistant == null) {
      thread = ConversationThread(
        conversation: thread.conversation,
        messages: [...thread.messages, assistant],
      );
    }
    final run = _ChatRun(
      id: _idFactory(),
      thread: thread,
      assistantId: assistant.id,
      configuration: config,
      claim: claim,
      restoreOnStartupFailure: restoreOnStartupFailure,
    );
    _runs[run.conversationId] = run;
    _queueStartingIds.remove(run.conversationId);
    if (conversation?.id == run.conversationId) _thread = thread;
    _isSubmitting = false;
    _runErrors.remove(run.conversationId);
    notifyListeners();
    if (_shutdownFuture != null) {
      await _stopRun(run);
      return;
    }
    try {
      await _backgroundExecution.begin(
        run.id,
        onExpiration: () => _stopRun(
          run,
          reason: 'Background time expired. The partial response is saved. Retry to continue.',
        ),
      );
      if (run.finishing || run.stopRequested) return;
      final context = await _ollamaContext(
        run,
        run.thread.messages.where((message) => message.id != assistant.id),
      );
      if (run.finishing || run.stopRequested) return;
      if (config.webEnabled) {
        await _runWebAgent(run, context);
      } else {
        await _runLocalChat(run, context);
      }
    } on Object catch (error) {
      await _finishRun(
        run,
        run.stopRequested ||
                error is OllamaCancelledException ||
                error is WebAgentCancelledException
            ? MessageStatus.interrupted
            : MessageStatus.failed,
        error: run.stopRequested ? null : _friendlyError(error),
      );
    }
  }

  Future<void> _runLocalChat(
    _ChatRun run,
    List<OllamaChatMessage> context,
  ) async {
    final config = run.configuration;
    final request = OllamaChatRequest(
      model: run.thread.conversation.selectedModel,
      messages: context,
      think: config.profile.protocol == ServerProtocol.ollama && config.thinking
          ? true
          : null,
      options: run.thread.conversation.generationOptions.toOllamaJson(),
    );
    final chat = switch (config.profile.protocol) {
      ServerProtocol.ollama => config.ollama!.startChat(request),
      ServerProtocol.openAiCompatible => config.compatible!.startChat(request),
    };
    run.chat = chat;
    var sawDone = false;
    String? doneReason;
    await for (final chunk in chat.stream) {
      if (run.finishing || run.stopRequested) return;
      _applyChunk(run, chunk);
      sawDone = sawDone || chunk.done;
      if (chunk.done) {
        doneReason = chunk.doneReason;
        break;
      }
    }
    if (!sawDone && !run.stopRequested) {
      throw const OllamaStreamException(
        'The response stream ended without a completion marker.',
      );
    }
    final normal = doneReason == null || doneReason == 'stop';
    await _finishRun(
      run,
      run.stopRequested || !normal
          ? MessageStatus.interrupted
          : MessageStatus.complete,
      error: !run.stopRequested && !normal
          ? '${config.profile.name} stopped before completing the response ($doneReason).'
          : null,
    );
  }

  Future<void> _runWebAgent(
    _ChatRun active,
    List<OllamaChatMessage> context,
  ) async {
    final config = active.configuration;
    final key = config.webKey;
    if (key == null || key.isEmpty) throw StateError('Web Agent is not ready.');
    final agent = config.ollama != null
        ? _webAgentFactory(ollama: config.ollama!, apiKey: key)
        : _compatibleWebAgentFactory?.call(
            client: config.compatible!,
            apiKey: key,
          );
    if (agent == null)
      throw StateError('Web Agent transport is not configured.');
    final run = agent.run(
      model: active.thread.conversation.selectedModel,
      messages: context,
      think: config.thinking ? true : null,
      options: active.thread.conversation.generationOptions.toOllamaJson(),
    );
    active.agent = run;
    final iterator = StreamIterator<WebAgentEvent>(run.stream);
    active.iterator = iterator;
    var completed = false;
    while (await iterator.moveNext()) {
      if (active.finishing || active.stopRequested) return;
      final event = iterator.current;
      switch (event) {
        case WebAgentTurnStarted():
          break;
        case WebAgentProviderToolProgress():
          _applyChunk(
            active,
            OllamaChatChunk(
              model: active.thread.conversation.selectedModel,
              message: OllamaChatMessage(
                role: OllamaRole.assistant,
                content: '',
              ),
              done: false,
              toolProgress: event.progress,
            ),
          );
        case WebAgentThinkingDelta():
          _updateActive(
            active,
            (message) => message.copyWith(
              reasoning: '${message.reasoning ?? ''}${event.delta}',
            ),
          );
        case WebAgentContentDelta():
          _updateActive(
            active,
            (message) =>
                message.copyWith(content: message.content + event.delta),
          );
        case WebAgentToolActivity():
          _applyWebToolEvent(active, event);
        case WebAgentCompleted():
          completed = true;
          final transcript = event.messages
              .skip(context.length)
              .map((message) => message.toJson())
              .toList(growable: false);
          _updateActive(
            active,
            (message) => message.copyWith(
              content: event.answer,
              providerTranscriptJson: jsonEncode(transcript),
            ),
          );
        case WebAgentFailed():
          throw event.error;
      }
    }
    if (!completed && !active.stopRequested) {
      throw StateError('Web Agent ended without a final answer.');
    }
    await _finishRun(
      active,
      active.stopRequested ? MessageStatus.interrupted : MessageStatus.complete,
    );
  }

  void _applyChunk(_ChatRun run, OllamaChatChunk chunk) {
    _updateActive(run, (message) {
      final calls = List<ToolCall>.of(message.toolCalls);
      final results = List<ToolResult>.of(message.toolResults);
      final progress = chunk.toolProgress;
      if (progress != null) {
        final id =
            '${message.id}-remote-${progress.toolCallId ?? progress.tool ?? 'activity'}';
        final call = ToolCall(
          id: id,
          name: progress.tool ?? 'Activity',
          arguments: {
            if (progress.label != null) 'label': progress.label,
            if (progress.status != null) 'status': progress.status,
          },
        );
        final old = calls.indexWhere((item) => item.id == id);
        if (old < 0) {
          calls.add(call);
        } else {
          calls[old] = call;
        }
        if (const {
          'complete',
          'completed',
          'success',
          'succeeded',
          'error',
          'failed',
        }.contains(progress.status)) {
          results.removeWhere((item) => item.toolCallId == id);
          results.add(
            ToolResult(
              id: '$id-result',
              toolCallId: id,
              content: progress.label ?? progress.status!,
              isError:
                  progress.status == 'error' || progress.status == 'failed',
            ),
          );
        }
      }
      for (
        var callPosition = 0;
        callPosition < chunk.message.toolCalls.length;
        callPosition++
      ) {
        final call = chunk.message.toolCalls[callPosition];
        final callId =
            '${message.id}-tool-${call.id ?? (call.index == null ? 's$callPosition' : 'i${call.index}')}';
        final existingIndex = calls.indexWhere(
          (existing) => existing.id == callId,
        );
        final domainCall = ToolCall(
          id: callId,
          name: call.name,
          arguments: Map<String, Object?>.from(call.arguments),
        );
        if (existingIndex < 0) {
          calls.add(domainCall);
        } else {
          calls[existingIndex] = domainCall;
        }
      }
      return message.copyWith(
        content: message.content + chunk.message.content,
        reasoning: '${message.reasoning ?? ''}${chunk.message.thinking}',
        toolCalls: calls,
        toolResults: results,
      );
    });
  }

  void _applyWebToolEvent(_ChatRun run, WebAgentToolActivity event) {
    _updateActive(run, (message) {
      final calls = List<ToolCall>.of(message.toolCalls);
      final results = List<ToolResult>.of(message.toolResults);
      final officialIndex = event.call.index;
      final callId = officialIndex == null
          ? run.syntheticToolIds.putIfAbsent(event.call, () {
              final syntheticIndex = run.nextToolIndex.update(
                event.turn,
                (current) => current + 1,
                ifAbsent: () => 0,
              );
              return '${message.id}-t${event.turn}-s$syntheticIndex';
            })
          : '${message.id}-t${event.turn}-i$officialIndex';
      final existingCall = calls.indexWhere((call) => call.id == callId);
      final domainCall = ToolCall(
        id: callId,
        name: event.call.name,
        arguments: Map<String, Object?>.from(event.call.arguments),
      );
      if (existingCall < 0) {
        calls.add(domainCall);
      } else {
        calls[existingCall] = domainCall;
      }

      if (event.state != WebToolActivityState.running) {
        final result = ToolResult(
          id: '$callId-result',
          toolCallId: callId,
          content: event.result == null
              ? (event.error?.message ?? 'Tool failed')
              : jsonEncode(event.result!.toJson()),
          isError: event.state == WebToolActivityState.failed,
        );
        final existingResult = results.indexWhere(
          (candidate) => candidate.toolCallId == callId,
        );
        if (existingResult < 0) {
          results.add(result);
        } else {
          results[existingResult] = result;
        }
      }
      return message.copyWith(toolCalls: calls, toolResults: results);
    });
  }

  Future<List<OllamaChatMessage>> _ollamaContext(
    _ChatRun run,
    Iterable<Message> source, {
    bool textOnly = false,
  }) async {
    var completeMessages = source
        .where(
          (message) =>
              message.status == MessageStatus.complete &&
              (!textOnly ||
                  message.role == MessageRole.user ||
                  message.role == MessageRole.assistant),
        )
        .toList(growable: false);
    final prompt = run.thread.conversation.systemPrompt.trim();
    final providerTranscripts = <String, List<OllamaChatMessage>>{};
    if (!textOnly) {
      for (final message in completeMessages) {
        final restored = _decodeProviderTranscript(
          message.providerTranscriptJson,
        );
        if (restored != null) providerTranscripts[message.id] = restored;
      }
    }
    // Keep user turns and their entire assistant/tool continuation together.
    final turns = <List<Message>>[];
    for (final message in completeMessages) {
      if (turns.isEmpty || message.role == MessageRole.user) turns.add([]);
      turns.last.add(message);
    }
    var textBytes = utf8.encode(prompt).length;
    var requestCount = prompt.isEmpty ? 0 : 1;
    var imageCount = 0;
    var imageBytes = 0;
    final configuredContext =
        run.thread.conversation.generationOptions.contextSize;
    final responseReserve = run.thread.conversation.generationOptions.maxTokens;
    final tokenBudget = configuredContext == null
        ? null
        : configuredContext -
              (responseReserve != null && responseReserve > 0
                  ? responseReserve
                  : (configuredContext ~/ 4));
    final retained = <List<Message>>[];
    for (final turn in turns.reversed) {
      var turnTextBytes = 0;
      var turnRequestCount = 0;
      var turnImages = 0;
      var turnImageBytes = 0;
      var oversizedMessage = false;
      for (final message in turn) {
        final restored = providerTranscripts[message.id];
        final pieces = <String>[];
        if (restored == null) {
          turnRequestCount++;
          pieces.add(message.content);
          pieces.addAll(message.documents.map((document) => document.text));
          turnTextBytes += message.documents.fold<int>(
            0,
            (total, document) =>
                total +
                utf8.encode(_documentContext(document)).length -
                utf8.encode(document.text).length,
          );
          if (!textOnly) pieces.add(message.reasoning ?? '');
        } else {
          turnRequestCount += restored.length;
          for (final item in restored) {
            pieces.addAll([item.content, item.thinking]);
            for (final call in item.toolCalls) {
              pieces.addAll([call.name, jsonEncode(call.arguments)]);
            }
          }
        }
        for (final piece in pieces) {
          final bytes = utf8.encode(piece).length;
          if (bytes > maxMessageTextBytes) oversizedMessage = true;
          turnTextBytes += bytes;
        }
        if (!textOnly) {
          turnImages += message.imageReferences.length;
          for (final reference in message.imageReferences) {
            try {
              turnImageBytes += await _images.sizeInBytes(reference);
            } on FileSystemException {
              // Existing missing-image recovery below handles selected turns.
            } on ArgumentError {
              // Existing invalid-reference recovery below handles selected turns.
            }
          }
        }
      }
      final nextBytes = textBytes + turnTextBytes;
      final nextCount = requestCount + turnRequestCount;
      final nextImages = imageCount + turnImages;
      // Conservative text estimate: one token per UTF-8 byte plus message
      // framing and a fixed image allowance. Actual tokenizer use varies.
      final estimatedTokens = nextBytes + nextCount * 16 + nextImages * 4096;
      final exceeds =
          oversizedMessage ||
          nextBytes > maxRequestTextBytes ||
          nextCount > maxRequestMessages ||
          nextImages > maxRequestImages ||
          imageBytes + turnImageBytes > maxRequestImageBytes ||
          (tokenBudget != null && estimatedTokens > tokenBudget);
      if (exceeds) {
        if (retained.isEmpty) {
          throw const ChatRequestLimitException(
            'The latest turn exceeds the request or context limit. Shorten it, '
            'remove an attachment, or increase the context size in Chat settings.',
          );
        }
        break;
      }
      retained.add(turn);
      textBytes = nextBytes;
      requestCount = nextCount;
      imageCount = nextImages;
      imageBytes += turnImageBytes;
    }
    final originalCount = completeMessages.length;
    completeMessages = retained.reversed.expand((turn) => turn).toList();
    final omitted = originalCount - completeMessages.length;
    _contextNoticeConversationId = run.conversationId;
    _contextNotice = omitted == 0
        ? null
        : 'Using recent context. $omitted older messages remain in history.';
    notifyListeners();

    final encodedImages = <String, List<String>>{};
    final repairedMessages = <String, Message>{};
    var totalImageBytes = 0;
    var recoveredLostImage = false;
    for (final message in textOnly ? const <Message>[] : completeMessages) {
      final encoded = <String>[];
      final retainedReferences = <String>[];
      for (final reference in message.imageReferences) {
        try {
          final bytes = await _images.sizeInBytes(reference);
          if (bytes <= 0) {
            throw FileSystemException('Image file is empty.', reference);
          }
          if (bytes > maxImageBytes) {
            throw const ChatRequestLimitException(
              'One image exceeds the 8 MB request limit.',
            );
          }
          totalImageBytes += bytes;
          if (totalImageBytes > maxRequestImageBytes) {
            throw const ChatRequestLimitException(
              'Chat images exceed the 24 MB request limit. Start a new chat.',
            );
          }
          encoded.add(await _images.readAsBase64(reference));
          retainedReferences.add(reference);
        } on ChatRequestLimitException {
          rethrow;
        } on FileSystemException {
          recoveredLostImage = true;
        } on ArgumentError {
          recoveredLostImage = true;
        }
      }
      encodedImages[message.id] = encoded;
      if (retainedReferences.length != message.imageReferences.length) {
        repairedMessages[message.id] = message.copyWith(
          imageReferences: List<String>.unmodifiable(retainedReferences),
          updatedAt: DateTime.now().toUtc(),
        );
      }
    }

    if (repairedMessages.isNotEmpty) {
      for (final repaired in repairedMessages.values) {
        await _conversations.updateMessage(repaired);
      }
      _replaceRunMessages(run, <Message>[
        for (final message in run.thread.messages)
          repairedMessages[message.id] ?? message,
      ]);
      notifyListeners();
    }
    if (recoveredLostImage) {
      throw const ChatRequestLimitException(
        'An attached image was missing from app storage and was removed. Retry the response.',
      );
    }

    final context = <OllamaChatMessage>[];
    if (prompt.isNotEmpty) {
      context.add(OllamaChatMessage(role: OllamaRole.system, content: prompt));
    }
    for (final message in completeMessages) {
      final restored = providerTranscripts[message.id];
      if (restored != null) {
        context.addAll(restored);
        continue;
      }
      context.add(
        OllamaChatMessage(
          role: _ollamaRole(message.role),
          content: [
            message.content,
            ...message.documents.map(_documentContext),
          ].join('\n\n'),
          thinking: textOnly ? '' : message.reasoning ?? '',
          images: textOnly
              ? const <String>[]
              : encodedImages[message.id] ?? const <String>[],
        ),
      );
    }
    return List.unmodifiable(context);
  }

  static String _documentContext(DocumentAttachment document) =>
      '--- Attached document: ${jsonEncode(document.name)} (${document.mimeType}) ---\n'
      '${document.text}\n--- End attached document ---';

  static List<OllamaChatMessage>? _decodeProviderTranscript(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.isEmpty) return null;
      return List<OllamaChatMessage>.unmodifiable(
        decoded.map((value) {
          if (value is! Map) {
            throw const FormatException('Invalid provider transcript message');
          }
          return OllamaChatMessage.fromJson(Map<String, dynamic>.from(value));
        }),
      );
    } on Object {
      return null;
    }
  }

  void _replaceRunMessages(_ChatRun run, List<Message> next) {
    final visible = conversation?.id == run.conversationId;
    run.thread = ConversationThread(
      conversation: visible ? _thread!.conversation : run.thread.conversation,
      messages: List.unmodifiable(next),
    );
    if (visible) _thread = run.thread;
  }

  void _updateActive(_ChatRun run, Message Function(Message current) update) {
    if (run.finishing) return;
    final messages = run.thread.messages;
    final index = messages.indexWhere(
      (message) => message.id == run.assistantId,
    );
    if (index < 0) return;
    final updated = update(messages[index])
        .copyWith(updatedAt: DateTime.now().toUtc());
    run.receivedOutput =
        run.receivedOutput ||
        updated.content.isNotEmpty ||
        (updated.reasoning?.isNotEmpty ?? false) ||
        updated.toolCalls.isNotEmpty;
    _replaceRunMessages(run, [
      for (var i = 0; i < messages.length; i++)
        if (i == index) updated else messages[i],
    ]);
    run.checkpointTimer ??= Timer(const Duration(milliseconds: 400), () {
      run.checkpointTimer = null;
      unawaited(_flushRunCheckpoint(run));
    });
    notifyListeners();
  }

  Future<void> _flushRunCheckpoint(_ChatRun run) {
    run.checkpointTimer?.cancel();
    run.checkpointTimer = null;
    if (run.finishing) return run.checkpointTail;
    final snapshot = run.thread.messages
        .where((message) => message.id == run.assistantId)
        .firstOrNull;
    if (snapshot == null) return run.checkpointTail;
    run.checkpointTail = run.checkpointTail.then((_) async {
      try {
        await _conversations.updateMessage(snapshot);
      } on Object catch (error) {
        _runErrors[run.conversationId] =
            'The partial response could not be saved: $error';
        notifyListeners();
      }
    });
    return run.checkpointTail;
  }

  Future<void> _finishRun(
    _ChatRun run,
    MessageStatus status, {
    String? error,
  }) async {
    if (run.finishing) return run.finished.future;
    run.finishing = true;
    run.checkpointTimer?.cancel();
    run.checkpointTimer = null;
    final id = run.conversationId;
    var saved = false;
    if (status != MessageStatus.complete) _queuePausedIds.add(id);
    try {
      await run.checkpointTail;
      final claim = run.claim;
      if (status == MessageStatus.failed &&
          !run.receivedOutput &&
          run.restoreOnStartupFailure &&
          claim != null) {
        await _conversations.restoreQueuedPrompt(claim);
        await _reloadQueues();
        await _refreshVisibleConversation(id, run.configuration.profile.id);
      } else {
        final messages = run.thread.messages;
        final index = messages.indexWhere(
          (message) => message.id == run.assistantId,
        );
        if (index >= 0) {
          final updated = messages[index].copyWith(
            status: status,
            updatedAt: DateTime.now().toUtc(),
          );
          _replaceRunMessages(run, [
            for (var i = 0; i < messages.length; i++)
              if (i == index) updated else messages[i],
          ]);
          await _conversations.updateMessage(updated);
        }
      }
      saved = true;
      if (error != null) _runErrors[id] = error;
      await _reloadHistory();
    } on Object catch (persistenceError) {
      _queuePausedIds.add(id);
      _runErrors[id] = 'The response could not be saved: $persistenceError';
    } finally {
      try {
        await _backgroundExecution.end(run.id);
      } on Object catch (releaseError) {
        _runErrors[id] = 'Background execution could not end: $releaseError';
      }
      if (identical(_runs[id], run)) _runs.remove(id);
      if (!run.finished.isCompleted) run.finished.complete();
      notifyListeners();
    }
    if (saved &&
        status == MessageStatus.complete &&
        !_queuePausedIds.contains(id) &&
        _shutdownFuture == null) {
      // The completed dispatch unwinds before the next queue claim starts.
      Timer.run(() => unawaited(_drainQueue(id, run.configuration)));
    }
  }

  Future<ConversationThread?> _ensureConversation() async {
    if (_thread != null) return _thread;
    final model = _selectedModel;
    if (model == null) return null;
    await _createConversation(model: model, systemPrompt: systemPrompt);
    return _thread;
  }

  Future<void> _createConversation({
    required String model,
    required String systemPrompt,
    bool advanceDraftScope = false,
  }) async {
    final oldKey = draftKey;
    final draft = _draft;
    final conversation = await _conversations.createConversation(
      id: draft.reservedId ?? _idFactory(),
      serverProfileId: activeProfileId,
      selectedModel: model,
      systemPrompt: systemPrompt,
      generationOptions: draft.options ?? chatDefaults.generationOptions,
    );
    _drafts.remove(oldKey);
    _drafts[conversation.id] = draft;
    await flushDrafts();
    if (advanceDraftScope) {
      _draftScopeRevision += 1;
      _contextNotice = null;
    }
    _thread = ConversationThread(
      conversation: conversation,
      messages: const [],
    );
    if (advanceDraftScope) notifyListeners();
    await _reloadHistory();
    notifyListeners();
  }

  Future<void> _openConversationInternal(
    String id, {
    String? profileId,
    bool advanceDraftScope = false,
  }) async {
    final live = _runs[id];
    if (live != null) {
      _thread = live.thread;
      if (advanceDraftScope) _draftScopeRevision += 1;
      notifyListeners();
      return;
    }
    var thread = await _conversations.openConversation(
      serverProfileId: profileId ?? activeProfileId,
      id: id,
    );
    if (thread == null) return;
    final normalized = <Message>[];
    for (final message in thread.messages) {
      if (message.status == MessageStatus.streaming ||
          message.status == MessageStatus.queued) {
        final interrupted = message.copyWith(
          status: MessageStatus.interrupted,
          updatedAt: DateTime.now().toUtc(),
        );
        await _conversations.updateMessage(interrupted);
        normalized.add(interrupted);
      } else {
        normalized.add(message);
      }
    }
    thread = ConversationThread(
      conversation: thread.conversation,
      messages: List.unmodifiable(normalized),
    );
    if (advanceDraftScope) _draftScopeRevision += 1;
    _thread = thread;
    notifyListeners();
  }

  Future<void> _reloadHistory() async {
    _history = List.unmodifiable(await _conversations.listAllConversations());
    _syncRevision++;
  }

  Future<void> _discardPendingImage([String? reference]) async {
    final removed = reference == null
        ? List<String>.of(_draft.images)
        : _draft.images.where((image) => image == reference).toList();
    _draft.images = _draft.images
        .where((image) => !removed.contains(image))
        .toList();
    await flushDrafts();
    if (_draftPersistenceError == null) {
      for (final image in removed) {
        await _deleteUnusedAttachment(image);
      }
    }
    notifyListeners();
  }

  Future<void> _deleteUnusedAttachment(String reference) async {
    if (_drafts.values.any(
          (draft) =>
              draft.images.contains(reference) ||
              draft.documents.any(
                (document) => document.reference == reference,
              ),
        ) ||
        await _conversations.isAttachmentReferenceInUse(reference))
      return;
    try {
      await _images.deleteReference(reference);
    } on Object catch (error) {
      _errorMessage = 'An unused attachment could not be removed: $error';
    }
  }

  void _replaceMessages(List<Message> next) {
    final current = _thread;
    if (current == null) return;
    _thread = ConversationThread(
      conversation: current.conversation,
      messages: List.unmodifiable(next),
    );
  }

  TranscriptMessageView _toTranscriptMessage(
    Message message, {
    required bool canRetry,
  }) {
    final resultsByCall = <String, ToolResult>{
      for (final result in message.toolResults) result.toolCallId: result,
    };
    return TranscriptMessageView(
      id: message.id,
      role: switch (message.role) {
        MessageRole.user => TranscriptRole.user,
        MessageRole.assistant => TranscriptRole.assistant,
        MessageRole.system || MessageRole.tool => TranscriptRole.system,
      },
      status: _transcriptStatus(message.status),
      canRetry: canRetry,
      canEdit: message.role == MessageRole.user,
      editRemovesLaterMessages: message.position < messages.last.position,
      canRegenerate: message.role == MessageRole.assistant,
      regenerateRemovesLaterMessages: message.position < messages.last.position,
      content: message.content,
      thinking: message.reasoning,
      imageReferences: message.imageReferences,
      documents: message.documents,
      toolCalls: [
        for (final call in message.toolCalls)
          _toToolActivity(
            call,
            resultsByCall[call.id],
            message.status == MessageStatus.streaming,
          ),
      ],
    );
  }

  ToolActivityView _toToolActivity(
    ToolCall call,
    ToolResult? result,
    bool messageStreaming,
  ) {
    final arguments = jsonEncode(call.arguments);
    final detail = result?.content ?? arguments;
    final rawLabel = call.arguments['label'];
    return ToolActivityView(
      label: rawLabel is String && rawLabel.trim().isNotEmpty
          ? rawLabel
          : _humanize(call.name),
      detail: _excerpt(detail, 1200),
      state: result == null
          ? (messageStreaming
                ? ToolActivityState.running
                : ToolActivityState.pending)
          : (result.isError
                ? ToolActivityState.failed
                : ToolActivityState.succeeded),
    );
  }

  static TranscriptStatus _transcriptStatus(MessageStatus status) =>
      switch (status) {
        MessageStatus.queued => TranscriptStatus.queued,
        MessageStatus.streaming => TranscriptStatus.streaming,
        MessageStatus.complete => TranscriptStatus.completed,
        MessageStatus.partial ||
        MessageStatus.interrupted => TranscriptStatus.interrupted,
        MessageStatus.failed => TranscriptStatus.failed,
      };

  static OllamaRole _ollamaRole(MessageRole role) => switch (role) {
    MessageRole.system => OllamaRole.system,
    MessageRole.user => OllamaRole.user,
    MessageRole.assistant => OllamaRole.assistant,
    MessageRole.tool => OllamaRole.tool,
  };

  static Conversation _copyConversation(
    Conversation source, {
    String? title,
    String? selectedModel,
    String? systemPrompt,
    GenerationOptions? generationOptions,
    DateTime? updatedAt,
  }) => Conversation(
    id: source.id,
    serverProfileId: source.serverProfileId,
    title: title ?? source.title,
    isPinned: source.isPinned,
    isArchived: source.isArchived,
    isRenamed: source.isRenamed,
    selectedModel: selectedModel ?? source.selectedModel,
    systemPrompt: systemPrompt ?? source.systemPrompt,
    generationOptions: generationOptions ?? source.generationOptions,
    createdAt: source.createdAt,
    updatedAt: updatedAt ?? source.updatedAt,
  );

  static String _humanize(String value) {
    final words = value.trim().replaceAll('_', ' ');
    if (words.isEmpty) return 'Tool';
    return '${words[0].toUpperCase()}${words.substring(1)}';
  }

  static String _excerpt(String value, int limit) =>
      value.length <= limit ? value : '${value.substring(0, limit)}…';

  static String _friendlyError(Object error) {
    if (error is LocalNetworkPreflightException) return error.message;
    if (error is OllamaException) return error.message;
    if (error is WebAgentException) return error.message;
    if (error is ChatRequestLimitException) return error.message;
    if (error is FormatException) return error.message.toString();
    return error.toString();
  }

  Future<void> shutdown() {
    return _shutdownFuture ??= _shutdownInOrder();
  }

  Future<void> _shutdownInOrder() async {
    await _chatSync?.close();
    await cancelModelPull();
    await Future.wait(_runs.values.toList().map(_stopRun));
    await _submissionCompleter?.future;
    await Future.wait(_queueDrains.toList());
    await flushDrafts();
    await _backgroundExecution.dispose();
  }

  @override
  void dispose() {
    for (final run in _runs.values) {
      run.checkpointTimer?.cancel();
    }
    _chatSync?.removeListener(notifyListeners);
    _chatSync?.dispose();
    super.dispose();
  }
}
