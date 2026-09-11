import 'package:flutter_test/flutter_test.dart';

import '../../lib/data/settings_store.dart';

void main() {
  test('server profiles and non-secret preferences round-trip', () async {
    final preferences = MemoryPreferences();
    final store = SettingsStore(preferences);

    final defaults = store.load();
    expect(defaults.baseUrl, SettingsStore.defaultBaseUrl);
    expect(defaults.insecureLanAcknowledged, isFalse);
    expect(defaults.theme, ThemePreference.system);
    expect(defaults.webAgentEnabled, isFalse);

    await store.setBaseUrl('  http://ollama.lan:11434/  ');
    await store.setInsecureLanAcknowledged(true);
    await store.setTheme(ThemePreference.dark);
    await store.setWebAgentEnabled(true);

    final saved = store.load();
    expect(saved.baseUrl, 'http://ollama.lan:11434');
    expect(saved.insecureLanAcknowledged, isTrue);
    expect(saved.theme, ThemePreference.dark);
    expect(saved.webAgentEnabled, isTrue);
    expect(preferences.values.keys.toSet(), <String>{
      'server_profiles_v1',
      'theme',
      'web_agent_enabled',
    });

    await store.setBaseUrl('http://different-ollama.lan:11434');
    expect(store.load().insecureLanAcknowledged, isFalse);

    final legacyPreferences = MemoryPreferences()
      ..values['base_url'] = 'http://legacy-ollama.lan:11434'
      ..values['insecure_lan_acknowledged'] = true;
    expect(
      SettingsStore(legacyPreferences).load().insecureLanAcknowledged,
      isFalse,
    );
  });
}

class MemoryPreferences implements PreferencesDriver {
  final Map<String, Object> values = <String, Object>{};

  @override
  bool? getBool(String key) => values[key] as bool?;

  @override
  String? getString(String key) => values[key] as String?;

  @override
  Future<void> setBool(String key, bool value) async {
    values[key] = value;
  }

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}
