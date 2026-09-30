import 'dart:convert';

import '../domain/generation_options.dart';
import '../domain/prompt_preset.dart';

enum ThemePreference { system, light, dark }

enum ServerProtocol { ollama, openAiCompatible }

abstract interface class PreferencesDriver {
  String? getString(String key);
  bool? getBool(String key);
  Future<void> setString(String key, String value);
  Future<void> setBool(String key, bool value);
}

final class ServerProfile {
  factory ServerProfile({
    required String id,
    required String name,
    required ServerProtocol protocol,
    required String baseUrl,
    String? acknowledgedInsecureOrigin,
    bool configured = true,
  }) {
    final normalizedId = id.trim();
    final normalizedName = name.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(id, 'id', 'profile ID must not be empty');
    }
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'profile name must not be empty');
    }

    final canonicalBaseUrl = SettingsStore.canonicalBaseUrl(baseUrl);
    final uri = Uri.parse(canonicalBaseUrl);
    final origin = SettingsStore.endpointOrigin(canonicalBaseUrl);
    final acknowledgedOrigin = acknowledgedInsecureOrigin?.trim();
    return ServerProfile._(
      id: normalizedId,
      name: normalizedName,
      protocol: protocol,
      baseUrl: canonicalBaseUrl,
      acknowledgedInsecureOrigin:
          uri.scheme == 'http' && acknowledgedOrigin == origin ? origin : null,
      configured: configured,
    );
  }

  const ServerProfile._({
    required this.id,
    required this.name,
    required this.protocol,
    required this.baseUrl,
    required this.acknowledgedInsecureOrigin,
    required this.configured,
  });

  final String id;
  final String name;
  final ServerProtocol protocol;
  final String baseUrl;
  final String? acknowledgedInsecureOrigin;

  /// False only for the synthesized bootstrap profile of a fresh install that
  /// the user has not saved through the connection form.
  final bool configured;

  bool get insecureLanAcknowledged =>
      Uri.parse(baseUrl).scheme == 'http' &&
      acknowledgedInsecureOrigin == SettingsStore.endpointOrigin(baseUrl);

  ServerProfile copyWith({
    String? name,
    ServerProtocol? protocol,
    String? baseUrl,
    Object? acknowledgedInsecureOrigin = _notProvided,
    bool? configured,
  }) => ServerProfile(
    id: id,
    name: name ?? this.name,
    protocol: protocol ?? this.protocol,
    baseUrl: baseUrl ?? this.baseUrl,
    acknowledgedInsecureOrigin:
        identical(acknowledgedInsecureOrigin, _notProvided)
        ? this.acknowledgedInsecureOrigin
        : acknowledgedInsecureOrigin as String?,
    configured: configured ?? this.configured,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'protocol': protocol.name,
    'baseUrl': baseUrl,
    if (acknowledgedInsecureOrigin != null)
      'acknowledgedInsecureOrigin': acknowledgedInsecureOrigin,
    // Absent means configured, so every pre-existing stored profile keeps it.
    if (!configured) 'configured': false,
  };

  factory ServerProfile.fromJson(Map<String, Object?> json) => ServerProfile(
    id: json['id']! as String,
    name: json['name']! as String,
    protocol: SettingsStore.readServerProtocol(json['protocol'] as String?),
    baseUrl: json['baseUrl']! as String,
    acknowledgedInsecureOrigin: json['acknowledgedInsecureOrigin'] as String?,
    configured: json['configured'] != false,
  );

  static const Object _notProvided = Object();
}

/// App-wide defaults, copied into a conversation when its first message is sent.
final class ChatDefaults {
  const ChatDefaults({
    this.systemPrompt = '',
    this.generationOptions = const GenerationOptions(),
  });
  final String systemPrompt;
  final GenerationOptions generationOptions;
  Map<String, Object?> toJson() => {
    'systemPrompt': systemPrompt,
    'generationOptions': generationOptions.toOllamaJson(),
  };
}

class LocalSettings {
  LocalSettings({
    required this.baseUrl,
    this.serverProtocol = ServerProtocol.ollama,
    required bool insecureLanAcknowledged,
    required this.theme,
    required this.webAgentEnabled,
  }) : _insecureLanAcknowledgedOrigin = insecureLanAcknowledged
           ? SettingsStore.endpointOrigin(baseUrl)
           : null;

  final String baseUrl;
  final ServerProtocol serverProtocol;
  final String? _insecureLanAcknowledgedOrigin;
  final ThemePreference theme;
  final bool webAgentEnabled;

  bool get insecureLanAcknowledged =>
      _insecureLanAcknowledgedOrigin != null &&
      _insecureLanAcknowledgedOrigin == SettingsStore.endpointOrigin(baseUrl);
}

class SettingsStore {
  SettingsStore(this._preferences);

  static const defaultBaseUrl = 'http://localhost:11434';
  static const defaultProfileId = 'default';
  static const _profilesKey = 'server_profiles_v1';
  static const _legacyBaseUrlKey = 'base_url';
  static const _legacyServerProtocolKey = 'server_protocol';
  static const _legacyInsecureLanAcknowledgedOriginKey =
      'insecure_lan_acknowledged_origin';
  static const _acknowledgedDestinationsKey = 'acknowledged_destinations_v1';
  static const _themeKey = 'theme';
  static const _webAgentEnabledKey = 'web_agent_enabled';

  final PreferencesDriver _preferences;

  Map<String, String> get syncBaseline {
    final value = _preferences.getString('chat_sync_baseline_v1');
    return value == null
        ? {}
        : Map<String, String>.from(jsonDecode(value) as Map);
  }

  Future<void> saveSyncBaseline(Map<String, String> value) =>
      _preferences.setString('chat_sync_baseline_v1', jsonEncode(value));

  List<PromptPreset> get promptPresets {
    final stored = _preferences.getString('prompt_presets_v1');
    if (stored == null) return const [];
    return List<PromptPreset>.unmodifiable(
      (jsonDecode(stored) as List).map(
        (value) =>
            PromptPreset.fromJson(Map<String, Object?>.from(value as Map)),
      ),
    );
  }

  Future<void> savePromptPresets(List<PromptPreset> presets) =>
      _preferences.setString(
        'prompt_presets_v1',
        jsonEncode(presets.map((preset) => preset.toJson()).toList()),
      );

  /// Persists the former single-server settings as the first named profile.
  /// The legacy keys remain readable but are no longer mutated.
  ///
  /// A stored profile document, any legacy single-server key, or existing
  /// local history ([hasLocalHistory]) is evidence of an existing installation,
  /// whose profile stays configured. Only a fresh installation gets an
  /// unconfigured bootstrap profile.
  Future<void> migrateLegacyProfile({bool hasLocalHistory = false}) async {
    final current = _readProfileDocument();
    if (current != null) {
      if (current.activeProfileId == null ||
          !current.profiles.any(
            (profile) => profile.id == current.activeProfileId,
          )) {
        await _writeProfileDocument(
          _ProfileDocument(
            profiles: current.profiles,
            activeProfileId: current.profiles.first.id,
          ),
        );
      }
      return;
    }
    final profile = _legacyProfile(
      configured: hasLocalHistory || _hasLegacyConfiguration,
    );
    await _writeProfileDocument(
      _ProfileDocument(
        profiles: <ServerProfile>[profile],
        activeProfileId: profile.id,
      ),
    );
  }

  bool get _hasLegacyConfiguration =>
      _preferences.getString(_legacyBaseUrlKey) != null ||
      _preferences.getString(_legacyServerProtocolKey) != null ||
      _preferences.getString(_legacyInsecureLanAcknowledgedOriginKey) != null;

  /// Whether the user acknowledged sending chat content to this exact
  /// protocol and canonical endpoint.
  bool isDestinationAcknowledged(ServerProtocol protocol, String baseUrl) =>
      _acknowledgedDestinations.contains(_destinationKey(protocol, baseUrl));

  Future<void> acknowledgeDestination(ServerProtocol protocol, String baseUrl) {
    final values = _acknowledgedDestinations
      ..add(_destinationKey(protocol, baseUrl));
    return _preferences.setString(
      _acknowledgedDestinationsKey,
      jsonEncode(values.toList()..sort()),
    );
  }

  Set<String> get _acknowledgedDestinations {
    final raw = _preferences.getString(_acknowledgedDestinationsKey);
    if (raw == null) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded.whereType<String>().toSet() : {};
    } on FormatException {
      return <String>{};
    }
  }

  static String _destinationKey(ServerProtocol protocol, String baseUrl) =>
      '${protocol.name} ${canonicalBaseUrl(baseUrl)}';

  LocalSettings load() {
    final profile = activeProfile;
    return LocalSettings(
      baseUrl: profile.baseUrl,
      serverProtocol: profile.protocol,
      insecureLanAcknowledged: profile.insecureLanAcknowledged,
      theme: _readTheme(_preferences.getString(_themeKey)),
      webAgentEnabled: _preferences.getBool(_webAgentEnabledKey) ?? false,
    );
  }

  List<ServerProfile> listProfiles() => List<ServerProfile>.unmodifiable(
    (_readProfileDocument() ?? _legacyDocument()).profiles,
  );

  String get activeProfileId {
    final document = _readProfileDocument() ?? _legacyDocument();
    final activeId = document.activeProfileId;
    if (activeId != null &&
        document.profiles.any((profile) => profile.id == activeId)) {
      return activeId;
    }
    return document.profiles.first.id;
  }

  ServerProfile get activeProfile {
    final profiles = listProfiles();
    final activeId = activeProfileId;
    return profiles.firstWhere(
      (profile) => profile.id == activeId,
      orElse: () => profiles.first,
    );
  }

  Future<void> upsertProfile(ServerProfile profile) async {
    final document = _readProfileDocument() ?? _legacyDocument();
    final profiles = List<ServerProfile>.of(document.profiles);
    final index = profiles.indexWhere(
      (candidate) => candidate.id == profile.id,
    );
    if (index < 0) {
      profiles.add(profile);
    } else {
      profiles[index] = profile;
    }
    await _writeProfileDocument(
      _ProfileDocument(
        profiles: profiles,
        activeProfileId: document.activeProfileId ?? profiles.first.id,
      ),
    );
  }

  Future<void> deleteProfile(String id) async {
    final document = _readProfileDocument() ?? _legacyDocument();
    final index = document.profiles.indexWhere((profile) => profile.id == id);
    if (index < 0) return;
    if (document.profiles.length == 1) {
      throw StateError('The last server profile cannot be deleted.');
    }

    final profiles = List<ServerProfile>.of(document.profiles)..removeAt(index);
    final replacementIndex = index < profiles.length
        ? index
        : profiles.length - 1;
    final activeId = document.activeProfileId == id
        ? profiles[replacementIndex].id
        : document.activeProfileId;
    await _writeProfileDocument(
      _ProfileDocument(profiles: profiles, activeProfileId: activeId),
    );
  }

  Future<void> setActiveProfile(String id) async {
    final document = _readProfileDocument() ?? _legacyDocument();
    if (!document.profiles.any((profile) => profile.id == id)) {
      throw ArgumentError.value(id, 'id', 'unknown server profile');
    }
    await _writeProfileDocument(
      _ProfileDocument(profiles: document.profiles, activeProfileId: id),
    );
  }

  // Compatibility setters update the active named profile.
  Future<void> setBaseUrl(String value) async {
    final current = activeProfile;
    final canonical = canonicalBaseUrl(value);
    final retainsAcknowledgement =
        endpointOrigin(canonical) == endpointOrigin(current.baseUrl);
    await upsertProfile(
      current.copyWith(
        baseUrl: canonical,
        acknowledgedInsecureOrigin: retainsAcknowledgement
            ? current.acknowledgedInsecureOrigin
            : null,
      ),
    );
  }

  Future<void> setServerProtocol(ServerProtocol value) =>
      upsertProfile(activeProfile.copyWith(protocol: value));

  Future<void> setInsecureLanAcknowledged(bool value) => upsertProfile(
    activeProfile.copyWith(
      acknowledgedInsecureOrigin: value
          ? endpointOrigin(activeProfile.baseUrl)
          : null,
    ),
  );

  Future<void> setTheme(ThemePreference value) =>
      _preferences.setString(_themeKey, value.name);

  ChatDefaults get chatDefaults {
    final raw = _preferences.getString('chat_defaults_v1');
    if (raw == null) return const ChatDefaults();
    final json = Map<String, Object?>.from(jsonDecode(raw) as Map);
    return ChatDefaults(
      systemPrompt: json['systemPrompt'] as String? ?? '',
      generationOptions: GenerationOptions.fromJson(
        Map<String, Object?>.from(
          json['generationOptions'] as Map? ?? const {},
        ),
      ),
    );
  }

  Future<void> setChatDefaults(ChatDefaults value) =>
      _preferences.setString('chat_defaults_v1', jsonEncode(value.toJson()));

  String? defaultModel(String profileId) {
    final value = _preferences.getString('default_model:$profileId');
    return value == null || value.isEmpty ? null : value;
  }

  Future<void> setDefaultModel(String profileId, String? model) =>
      _preferences.setString('default_model:$profileId', model ?? '');

  Set<String> compatibleCapabilities(String profileId) {
    final raw = _preferences.getString('compatible_capabilities:$profileId');
    if (raw == null) return const {};
    final values = jsonDecode(raw) as List;
    return values.cast<String>().toSet();
  }

  Future<void> setCompatibleCapabilities(
    String profileId,
    Set<String> values,
  ) => _preferences.setString(
    'compatible_capabilities:$profileId',
    jsonEncode(
      values
          .where((value) => const {'vision', 'tools'}.contains(value))
          .toList(),
    ),
  );

  String? lastSelectedModel(String profileId) =>
      _preferences.getString('last_model:$profileId');

  Future<void> rememberModel(String profileId, String model) =>
      _preferences.setString('last_model:$profileId', model);

  Future<void> setWebAgentEnabled(bool value) =>
      _preferences.setBool(_webAgentEnabledKey, value);

  _ProfileDocument _legacyDocument() {
    final profile = _legacyProfile(configured: _hasLegacyConfiguration);
    return _ProfileDocument(
      profiles: <ServerProfile>[profile],
      activeProfileId: profile.id,
    );
  }

  ServerProfile _legacyProfile({required bool configured}) {
    final rawBaseUrl =
        _preferences.getString(_legacyBaseUrlKey) ?? defaultBaseUrl;
    final baseUrl = canonicalBaseUrl(rawBaseUrl);
    final acknowledgedOrigin = _preferences.getString(
      _legacyInsecureLanAcknowledgedOriginKey,
    );
    return ServerProfile(
      id: defaultProfileId,
      name: 'Default',
      protocol: readServerProtocol(
        _preferences.getString(_legacyServerProtocolKey),
      ),
      baseUrl: baseUrl,
      acknowledgedInsecureOrigin: acknowledgedOrigin,
      configured: configured,
    );
  }

  _ProfileDocument? _readProfileDocument() {
    final raw = _preferences.getString(_profilesKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final json = Map<String, Object?>.from(decoded);
      final rawProfiles = json['profiles'];
      if (rawProfiles is! List) return null;
      final profiles = rawProfiles
          .whereType<Map>()
          .map(
            (profile) =>
                ServerProfile.fromJson(Map<String, Object?>.from(profile)),
          )
          .toList(growable: false);
      if (profiles.isEmpty ||
          profiles.map((profile) => profile.id).toSet().length !=
              profiles.length) {
        return null;
      }
      return _ProfileDocument(
        profiles: profiles,
        activeProfileId: json['activeProfileId'] as String?,
      );
    } on Object {
      return null;
    }
  }

  Future<void> _writeProfileDocument(_ProfileDocument document) {
    if (document.profiles.isEmpty) {
      throw StateError('At least one server profile is required.');
    }
    return _preferences.setString(
      _profilesKey,
      jsonEncode(<String, Object?>{
        'profiles': document.profiles
            .map((profile) => profile.toJson())
            .toList(growable: false),
        'activeProfileId': document.activeProfileId,
      }),
    );
  }

  static String canonicalBaseUrl(String value) {
    final uri = Uri.parse(value.trim());
    if ((uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      throw FormatException('Server base URL must be an HTTP(S) URL', value);
    }
    if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) {
      throw FormatException(
        'Server base URL must not contain credentials, query, or fragment',
        value,
      );
    }
    final path = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .join('/');
    return uri
        .replace(
          scheme: uri.scheme.toLowerCase(),
          host: uri.host.toLowerCase(),
          path: path.isEmpty ? '' : '/$path',
        )
        .toString();
  }

  static String? endpointOrigin(String value) {
    Uri uri;
    try {
      uri = Uri.parse(canonicalBaseUrl(value));
    } on FormatException {
      return null;
    }
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).origin;
  }

  static ThemePreference _readTheme(String? value) {
    for (final theme in ThemePreference.values) {
      if (theme.name == value) return theme;
    }
    return ThemePreference.system;
  }

  static ServerProtocol readServerProtocol(String? value) {
    for (final protocol in ServerProtocol.values) {
      if (protocol.name == value) return protocol;
    }
    return ServerProtocol.ollama;
  }
}

final class _ProfileDocument {
  const _ProfileDocument({
    required this.profiles,
    required this.activeProfileId,
  });

  final List<ServerProfile> profiles;
  final String? activeProfileId;
}
