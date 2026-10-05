import '../data/profile_credentials.dart';
import '../data/settings_store.dart';
import 'client.dart';
import 'store.dart';
import 'files.dart';

/// Saved connection metadata shares the app's profile document. Account-owned
/// data uses only WebUiStore; selecting it never changes a direct-chat owner.
final class WebUiAccounts {
  const WebUiAccounts(
    this.settings,
    this.credentials,
    this.store, {
    this.prepareConnection,
  });
  final SettingsStore settings;
  final ProfileCredentials credentials;
  final WebUiStore store;
  final Future<void> Function(ServerProfile)? prepareConnection;
  List<ServerProfile> get profiles => settings
      .listProfiles()
      .where((p) => p.protocol == ServerProtocol.openWebUi)
      .toList();

  Future<WebUiSession> open(
    ServerProfile profile, {
    String? email,
    String? password,
    String? token,
    Map<String, String>? headers,
  }) async {
    if (profile.protocol != ServerProtocol.openWebUi) {
      throw ArgumentError('Shared account profile required.');
    }
    await prepareConnection?.call(profile);
    final previous = settings
        .listProfiles()
        .where((p) => p.id == profile.id)
        .firstOrNull;
    if (previous != null &&
        (previous.protocol != profile.protocol ||
            previous.baseUrl != profile.baseUrl)) {
      throw const WebUiException(
        'Create a separate connection for another server.',
      );
    }
    final options = await credentials.options(
      profile,
      apiKey: token,
      customHeaders: headers,
    );
    var client = OpenWebUiClient(baseUrl: profile.baseUrl, options: options);
    try {
      if (email != null && password != null) {
        final result = await client.signIn(email, password);
        final issued = result['token'];
        if (issued is! String || issued.isEmpty) {
          throw const WebUiException('The server did not issue a login token.');
        }
        final authenticated = client.withToken(issued);
        client.close();
        client = authenticated;
      }
      final identity = await client.identity();
      final session = WebUiSession(profile.id, identity, client);
      // Identity alone does not establish shared-history access for restricted keys.
      await client.chats(lease: session.capture());
      await store.unlock(session.capture());
      await credentials.write(profile, client.options);
      await settings.upsertProfile(profile);
      await settings.acknowledgeDestination(profile.protocol, profile.baseUrl);
      await (await WebUiFiles.create()).reclaimAbandoned(
        session.capture(),
        await store.stagedReferences(session.capture()),
      );
      return session;
    } on Object {
      client.close();
      rethrow;
    }
  }

  Future<void> signOut(WebUiSession session) async {
    session.lock();
    session.client.close();
    await forgetStoredAccount(session.profileId);
  }

  Future<void> forgetStoredAccount(String profileId) async {
    final binding = await store.binding(profileId);
    for (final id in await store.boundProfiles(profileId)) {
      await credentials.store.delete(ProfileCredentials.key(id));
    }
    if (binding != null) {
      await (await WebUiFiles.create()).clearAccount(
        binding['server'] as String,
        binding['user_id'] as String,
      );
    }
    await store.clearStoredAccount(profileId);
  }

  Future<void> removeConnection(ServerProfile profile) async {
    await forgetStoredAccount(profile.id);
    await settings.deleteProfile(profile.id);
  }
}
