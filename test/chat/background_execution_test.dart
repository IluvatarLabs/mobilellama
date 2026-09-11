import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobollama/chat/background_execution.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  test('run expiration and terminal release are isolated by run id', () async {
    const channel = MethodChannel('test.mobollama/background-isolation');
    final nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    var firstExpired = 0;
    var secondExpired = 0;
    final execution = NativeChatBackgroundExecution(
      channel: channel,
      supportedPlatform: true,
    );
    addTearDown(execution.dispose);

    await execution.begin('run-one', onExpiration: () async => firstExpired++);
    await execution.begin('run-two', onExpiration: () async => secondExpired++);

    await _sendNativeCall(
      channel,
      const MethodCall('expired', {'runId': 'run-one'}),
    );
    expect(firstExpired, 1);
    expect(secondExpired, 0);

    await execution.end('run-two');
    await _sendNativeCall(
      channel,
      const MethodCall('expired', {'runId': 'run-two'}),
    );
    expect(secondExpired, 0);
    expect(nativeCalls.map((call) => call.method), ['begin', 'begin', 'end']);
    expect(nativeCalls.map((call) => call.arguments), [
      {'runId': 'run-one'},
      {'runId': 'run-two'},
      {'runId': 'run-two'},
    ]);
  });

  test('dispose releases native leases and ignores late expiration', () async {
    const channel = MethodChannel('test.mobollama/background-dispose');
    final nativeCalls = <MethodCall>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      nativeCalls.add(call);
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    var expirations = 0;
    final execution = NativeChatBackgroundExecution(
      channel: channel,
      supportedPlatform: true,
    );
    await execution.begin('run-one', onExpiration: () async => expirations++);
    await execution.begin('run-two', onExpiration: () async => expirations++);

    await execution.dispose();
    await execution.dispose();
    await _sendNativeCall(
      channel,
      const MethodCall('expired', {'runId': 'run-one'}),
    );

    expect(expirations, 0);
    expect(nativeCalls.map((call) => call.method), [
      'begin',
      'begin',
      'dispose',
    ]);
  });

  test(
    'missing native plugin and unsupported platforms use no-op behavior',
    () async {
      const missingChannel = MethodChannel('test.mobollama/background-missing');
      final missing = NativeChatBackgroundExecution(
        channel: missingChannel,
        supportedPlatform: true,
      );
      await missing.begin('run-one', onExpiration: () async {});
      await missing.end('run-one');
      await missing.dispose();

      const unsupportedChannel = MethodChannel(
        'test.mobollama/background-unsupported',
      );
      final nativeCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(unsupportedChannel, (call) async {
        nativeCalls.add(call);
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(unsupportedChannel, null),
      );
      final unsupported = NativeChatBackgroundExecution(
        channel: unsupportedChannel,
        supportedPlatform: false,
      );
      await unsupported.begin('run-two', onExpiration: () async {});
      await unsupported.end('run-two');
      await unsupported.dispose();
      expect(nativeCalls, isEmpty);
    },
  );

  test(
    'system grant refusal preserves foreground chat but other errors surface',
    () async {
      const unavailableChannel = MethodChannel(
        'test.mobollama/background-unavailable',
      );
      messenger.setMockMethodCallHandler(unavailableChannel, (call) async {
        if (call.method == 'begin') {
          throw PlatformException(
            code: 'background_unavailable',
            message: 'No finite grant is currently available.',
          );
        }
        return null;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(unavailableChannel, null),
      );
      final unavailable = NativeChatBackgroundExecution(
        channel: unavailableChannel,
        supportedPlatform: true,
      );
      await unavailable.begin('run-one', onExpiration: () async {});
      await unavailable.dispose();

      const brokenChannel = MethodChannel('test.mobollama/background-broken');
      messenger.setMockMethodCallHandler(brokenChannel, (call) async {
        throw PlatformException(
          code: 'bridge_failure',
          message: 'Native bridge failed.',
        );
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(brokenChannel, null),
      );
      final broken = NativeChatBackgroundExecution(
        channel: brokenChannel,
        supportedPlatform: true,
      );
      await expectLater(
        broken.begin('run-two', onExpiration: () async {}),
        throwsA(
          isA<ChatBackgroundExecutionException>().having(
            (error) => error.message,
            'message',
            contains('Native bridge failed.'),
          ),
        ),
      );
      await expectLater(
        broken.dispose(),
        throwsA(isA<ChatBackgroundExecutionException>()),
      );
    },
  );
}

Future<void> _sendNativeCall(MethodChannel channel, MethodCall call) {
  return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(call),
        (ByteData? _) {},
      );
}
