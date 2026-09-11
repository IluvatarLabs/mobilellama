final class DocumentAttachment {
  const DocumentAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.reference,
    required this.text,
  });

  static const maxPerMessage = 4;
  static const maxFileBytes = 8 * 1024 * 1024;
  static const maxExtractedTextBytes = 64 * 1024;

  final String id;
  final String name;
  final String mimeType;
  final String reference;
  final String text;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'reference': reference,
    'text': text,
  };

  factory DocumentAttachment.fromJson(Map<String, Object?> json) =>
      DocumentAttachment(
        id: _requiredString(json, 'id'),
        name: _requiredString(json, 'name'),
        mimeType: _requiredString(json, 'mimeType'),
        reference: _requiredString(json, 'reference'),
        text: _requiredString(json, 'text'),
      );

  DocumentAttachment copyWith({String? id, String? reference}) =>
      DocumentAttachment(
        id: id ?? this.id,
        name: name,
        mimeType: mimeType,
        reference: reference ?? this.reference,
        text: text,
      );

  static String _requiredString(Map<String, Object?> json, String field) {
    final value = json[field];
    if (value is! String) {
      throw FormatException('document $field must be a string');
    }
    return value;
  }
}
