import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/data/profile_credentials.dart';
import 'package:mobollama/data/settings_store.dart';
import 'package:mobollama/open_webui/accounts.dart';
import 'package:mobollama/open_webui/client.dart';

import '../support/chat_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'account traffic requires exact-server consent and sign-out withdraws it',
    () async {
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final fixture = ChatFixture();
      await fixture.open();
      addTearDown(fixture.close);
      final support = await Directory.systemTemp.createTemp('webui-consent-');
      addTearDown(() => support.delete(recursive: true));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => support.path);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null),
      );

      final requests = <String>[];
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        requests.add('${request.method} ${request.uri.path}');
        final Object response = switch (request.uri.path) {
          '/shared/api/v1/auths/signin' => {'token': 'issued-token'},
          '/shared/api/v1/auths/' => {
            'id': 'account-a',
            'name': 'Account A',
            'permissions': <String, Object?>{},
          },
          '/shared/api/v1/chats/' => <Object?>[],
          _ => {'detail': 'not found'},
        };
        request.response
          ..statusCode = request.uri.path.startsWith('/shared/api/') ? 200 : 404
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(response));
        await request.response.close();
      });

      final endpoint = 'http://${server.address.address}:${server.port}/shared';
      final profile = ServerProfile(
        id: 'shared-a',
        name: 'Shared A',
        protocol: ServerProtocol.openWebUi,
        baseUrl: endpoint,
      );
      var preparations = 0;
      final accounts = WebUiAccounts(
        fixture.settings,
        ProfileCredentials(fixture.secrets),
        fixture.store.webUi,
        prepareConnection: (_) async => preparations++,
      );

      await expectLater(
        accounts.open(profile, email: 'a@example.test', password: 'private'),
        throwsA(isA<WebUiException>()),
      );
      expect(requests, isEmpty);
      expect(preparations, 0);

      await fixture.settings.acknowledgeDestination(
        profile.protocol,
        profile.baseUrl,
      );
      final session = await accounts.open(
        profile,
        email: 'a@example.test',
        password: 'private',
      );
      expect(requests, [
        'POST /shared/api/v1/auths/signin',
        'GET /shared/api/v1/auths/',
        'GET /shared/api/v1/chats/',
      ]);
      expect(preparations, 1);

      await accounts.signOut(session);
      expect(
        fixture.settings.isDestinationAcknowledged(
          profile.protocol,
          profile.baseUrl,
        ),
        isFalse,
      );
      final requestCount = requests.length;
      await expectLater(
        accounts.open(
          ServerProfile(
            id: 'same-endpoint-alias',
            name: 'Shared alias',
            protocol: ServerProtocol.openWebUi,
            baseUrl: endpoint,
          ),
          token: 'another-token',
        ),
        throwsA(isA<WebUiException>()),
      );
      expect(requests, hasLength(requestCount));
      expect(preparations, 1);
    },
  );
}
