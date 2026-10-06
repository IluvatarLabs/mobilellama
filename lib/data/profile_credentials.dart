import 'dart:convert';

import '../ollama/connection_options.dart';
import 'settings_store.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

/// A single secure-storage record commits all slots for one profile together.
/// The binding prevents a saved credential from following an edited address.
final class ProfileCredentials {
  const ProfileCredentials(this.store);
  final SecretStore store;

  static String key(String id) => 'profile_credentials:$id';
  static String legacyKey(ServerProfile profile) =>
      'server_api_key:${profile.protocol.name}:${base64Url.encode(utf8.encode(profile.baseUrl))}';

  Future<Map<String, dynamic>> read(ServerProfile profile) async {
    final raw = await store.read(key(profile.id));
    if (raw == null) return {};
    final record = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    if (record['endpoint'] != profile.baseUrl ||
        record['protocol'] != profile.protocol.name) {
      return {};
    }
    return record;
  }

  Future<ConnectionOptions> options(
    ServerProfile profile, {
    String? apiKey,
    Map<String, String>? customHeaders,
  }) async {
    final record = await read(profile);
    final storedHeaders = Map<String, String>.from(
      record['headers'] as Map? ?? const {},
    );
    for (final name in profile.headerNames) {
      if (customHeaders?[name]?.isNotEmpty != true &&
          !storedHeaders.containsKey(name)) {
        throw FormatException('Enter a value for header "$name".');
      }
    }
    return ConnectionOptions(
      authentication: profile.authentication,
      compatibleApi: profile.compatibleApi,
      apiVersion: profile.apiVersion,
      apiKey: apiKey?.trim().isNotEmpty == true
          ? apiKey!.trim()
          : record['apiKey'] as String? ?? '',
      customHeaders: {
        for (final name in profile.headerNames)
          if (customHeaders?[name]?.isNotEmpty == true ||
              storedHeaders.containsKey(name))
            name: customHeaders?[name]?.isNotEmpty == true
                ? customHeaders![name]!
                : storedHeaders[name]!,
      },
    );
  }

  Future<void> write(ServerProfile profile, ConnectionOptions options) =>
      store.write(
        key(profile.id),
        jsonEncode({
          'endpoint': profile.baseUrl,
          'protocol': profile.protocol.name,
          'apiKey': options.apiKey,
          'headers': options.customHeaders,
        }),
      );

  /// Every dependent gets its own copy before deleting a shared legacy slot.
  /// Presence of the new record (including an empty key) is the durable receipt.
  Future<void> migrate(List<ServerProfile> profiles) async {
    final legacy = <String>{};
    for (final profile in profiles) {
      if (profile.protocol != ServerProtocol.openAiCompatible) continue;
      final oldKey = legacyKey(profile);
      legacy.add(oldKey);
      if (await store.read(key(profile.id)) != null) continue;
      final oldValue = await store.read(oldKey) ?? '';
      await write(profile, ConnectionOptions(apiKey: oldValue));
    }
    // Reached only after all copies committed; a crash can safely repeat this.
    for (final oldKey in legacy) {
      try {
        await store.delete(oldKey);
      } on Object {
        // Every dependent already has a durable independent record. Keep the
        // legacy slot for cleanup on next launch without blocking local chats.
      }
    }
  }
}
