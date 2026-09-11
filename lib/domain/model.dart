class OllamaModel {
  const OllamaModel({
    required this.name,
    this.digest,
    this.sizeBytes,
    this.modifiedAt,
    this.capabilities = const <String>[],
  });

  final String name;
  final String? digest;
  final int? sizeBytes;
  final DateTime? modifiedAt;
  final List<String> capabilities;

  bool get supportsTools => capabilities.contains('tools');
  bool get supportsImages => capabilities.contains('vision');
}
