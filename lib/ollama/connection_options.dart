import '../data/settings_store.dart';

/// Request configuration shared by the direct transports. Header values never
/// enter preferences, chat backups, or model metadata.
final class ConnectionOptions {
  ConnectionOptions({
    this.authentication = ServerAuthentication.bearer,
    this.apiKey = '',
    this.apiVersion = '',
    this.compatibleApi = CompatibleApi.chatCompletions,
    Map<String, String> customHeaders = const {},
  }) : customHeaders = Map.unmodifiable(customHeaders) {
    headers; // Reject ambiguous or invalid authentication before any request.
  }

  final ServerAuthentication authentication;
  final String apiKey;
  final String apiVersion;
  final CompatibleApi compatibleApi;
  final Map<String, String> customHeaders;

  Map<String, String> get headers {
    final values = <String, String>{'content-type': 'application/json'};
    if (apiKey.isNotEmpty) {
      switch (authentication) {
        case ServerAuthentication.none:
          break;
        case ServerAuthentication.bearer:
          values['authorization'] = 'Bearer $apiKey';
        case ServerAuthentication.apiKey:
          values['api-key'] = apiKey;
      }
    }
    for (final entry in customHeaders.entries) {
      final name = entry.key.trim().toLowerCase();
      if (!RegExp(r"^[!#$%&'*+.^_`|~0-9a-z-]+$").hasMatch(name) ||
          const {
            'host',
            'content-length',
            'connection',
            'transfer-encoding',
          }.contains(name) ||
          entry.value.contains('\r') ||
          entry.value.contains('\n')) {
        throw const FormatException('Invalid custom header name or value.');
      }
      if (values.containsKey(name)) {
        throw FormatException('Header "$name" conflicts with another header.');
      }
      values[name] = entry.value;
    }
    if (values.values.any(
      (value) => value.contains('\r') || value.contains('\n'),
    )) {
      throw const FormatException('Header values must be on one line.');
    }
    return values;
  }

  Uri endpoint(Uri root, String path) => root.replace(
    pathSegments: [
      ...root.pathSegments.where((part) => part.isNotEmpty),
      ...path.split('/').where((part) => part.isNotEmpty),
    ],
    queryParameters: apiVersion.isEmpty ? null : {'api-version': apiVersion},
  );

  String redact(String text) {
    for (final value in [apiKey, ...customHeaders.values]) {
      if (value.isNotEmpty) text = text.replaceAll(value, '[redacted]');
    }
    return text.replaceAll(
      RegExp(r'bearer\s+\S+', caseSensitive: false),
      'Bearer [redacted]',
    );
  }
}
