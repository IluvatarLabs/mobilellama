import 'package:shared_preferences/shared_preferences.dart';

import 'settings_store.dart';

final class SharedPreferencesDriver implements PreferencesDriver {
  const SharedPreferencesDriver(this._preferences);

  final SharedPreferences _preferences;

  static Future<SharedPreferencesDriver> load() async =>
      SharedPreferencesDriver(await SharedPreferences.getInstance());

  @override
  bool? getBool(String key) => _preferences.getBool(key);

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<void> setBool(String key, bool value) =>
      _preferences.setBool(key, value);

  @override
  Future<void> setString(String key, String value) =>
      _preferences.setString(key, value);
}

Future<SettingsStore> openSettingsStore() async {
  final store = SettingsStore(await SharedPreferencesDriver.load());
  await store.migrateLegacyProfile();
  return store;
}
