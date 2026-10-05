import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/data/profile_credentials.dart';

import '../support/chat_fixture.dart';

void main() {
  test('same-server credentials migrate independently and requests keep the selected profile', () async {
    final f = ChatFixture();
    await f.open();
    addTearDown(f.close);
    final a = ServerProfile(
      id: 'a',
      name: 'A',
      protocol: ServerProtocol.openAiCompatible,
      baseUrl: 'https://gateway.test/team/api',
    );
    final b = ServerProfile(
      id: 'b',
      name: 'B',
      protocol: a.protocol,
      baseUrl: a.baseUrl,
    );
    await f.settings.upsertProfile(a);
    await f.settings.upsertProfile(b);
    f.secrets.values[ProfileCredentials.legacyKey(a)] = 'legacy-key';
    await f.controller.initialize();
    final credentials = ProfileCredentials(f.secrets);
    expect((await credentials.options(a)).apiKey, 'legacy-key');
    expect((await credentials.options(b)).apiKey, 'legacy-key');
    expect(
      f.secrets.values.containsKey(ProfileCredentials.legacyKey(a)),
      isFalse,
    );
    final changed = a.copyWith(
      authentication: ServerAuthentication.apiKey,
      apiVersion: '2026-01-01',
      headerNames: ['x-gateway'],
    );
    expect(
      (await f.controller.saveAndConnectServerProfile(
        changed,
        serverApiKey: 'key-a',
        customHeaders: {'x-gateway': 'gateway-secret'},
      )).connection!.succeeded,
      isTrue,
    );
    expect(await f.controller.send('Through A'), isTrue);
    expect(f.requests.last['headers']['api-key'], 'key-a');
    expect(f.requests.last['headers']['x-gateway'], 'gateway-secret');
    expect(
      f.preferences.values.values.join(),
      isNot(contains('gateway-secret')),
    );
    await f.controller.newConversation();
    expect(await f.controller.switchServerProfile('b'), isTrue);
    expect(await f.controller.send('Through B'), isTrue);
    expect(f.requests.last['headers']['authorization'], 'Bearer legacy-key');
    await f.controller.removeServerApiKey(profileId: 'a');
    expect((await credentials.options(b)).apiKey, 'legacy-key');
    // Simulate secure-store reopening and a repeated migration after key removal.
    final reopened = ProfileCredentials(f.secrets);
    await reopened.migrate(f.settings.listProfiles());
    expect((await reopened.options(changed)).apiKey, isEmpty);
    expect((await reopened.options(b)).apiKey, 'legacy-key');
    expect(jsonEncode(changed.toJson()), isNot(contains('gateway-secret')));
  });
}
