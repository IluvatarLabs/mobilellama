import 'package:flutter/services.dart';

final class LocalNetworkPreflight {
  const LocalNetworkPreflight();

  static const MethodChannel _channel = MethodChannel(
    'app.mobollama/local_network',
  );

  Future<void> prepare({required String host, required int port}) async {
    try {
      await _channel.invokeMethod<void>('prepare', <String, Object>{
        'host': host,
        'port': port,
      });
    } on MissingPluginException {
      // The native preflight is iOS-only. Other platforms connect normally.
    } on PlatformException catch (error) {
      final detail = error.message?.trim();
      throw LocalNetworkPreflightException(
        detail == null || detail.isEmpty
            ? 'Local network access is unavailable. Allow Local Network access in Settings and try again.'
            : 'Local network access is unavailable: $detail',
      );
    }
  }
}

final class LocalNetworkPreflightException implements Exception {
  const LocalNetworkPreflightException(this.message);

  final String message;

  @override
  String toString() => message;
}
