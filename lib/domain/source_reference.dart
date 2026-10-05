import 'dart:convert';

/// Provider-supplied provenance. A bracketed number in text is not evidence.
class SourceReference {
  const SourceReference({
    required this.id,
    required this.title,
    this.url,
    this.fileId,
    this.excerpt,
  });
  final String id;
  final String title;
  final String? url;
  final String? fileId;
  final String? excerpt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    if (url != null) 'url': url,
    if (fileId != null) 'fileId': fileId,
    if (excerpt != null) 'excerpt': excerpt,
  };

  static SourceReference? fromAnnotation(Map annotation, String id) {
    switch (annotation['type']) {
      case 'url_citation':
        final url = annotation['url'];
        if (url is! String) return null;
        final uri = Uri.tryParse(url);
        if (uri == null ||
            !{'http', 'https'}.contains(uri.scheme) ||
            uri.host.isEmpty ||
            uri.userInfo.isNotEmpty) {
          return null;
        }
        return SourceReference(
          id: id,
          title: annotation['title'] as String? ?? uri.host,
          url: url,
        );
      case 'file_citation':
      case 'container_file_citation':
      case 'file_path':
        final fileId = annotation['file_id'];
        if (fileId is! String) return null;
        return SourceReference(
          id: id,
          title: annotation['filename'] as String? ?? 'Source file',
          fileId: fileId,
        );
      default:
        return null;
    }
  }

  static List<SourceReference> fromProviderItems(
    List<Map<String, dynamic>> items,
  ) {
    final sources = <SourceReference>[];
    for (var i = 0; i < items.length; i++) {
      final item = items[i];
      final parts = item['content'];
      if (item['type'] != 'message' || parts is! List) continue;
      for (var partIndex = 0; partIndex < parts.length; partIndex++) {
        final part = parts[partIndex];
        if (part is! Map || part['annotations'] is! List) continue;
        final annotations = part['annotations'] as List;
        for (var a = 0; a < annotations.length; a++) {
          if (annotations[a] is! Map) continue;
          final source = fromAnnotation(
            annotations[a] as Map,
            '${item['id'] ?? i}:$partIndex:$a',
          );
          if (source != null) sources.add(source);
        }
      }
    }
    return sources;
  }

  static List<SourceReference> fromTranscript(String? json) {
    if (json == null) return const [];
    final result = <String, SourceReference>{};
    try {
      for (final message in jsonDecode(json) as List) {
        for (final raw in message['source_references'] as List? ?? const []) {
          final source = SourceReference(
            id: raw['id'] as String,
            title: raw['title'] as String,
            url: raw['url'] as String?,
            fileId: raw['fileId'] as String?,
            excerpt: raw['excerpt'] as String?,
          );
          result[source.id] = source;
        }
        for (final source in fromProviderItems(
          (message['provider_items'] as List? ?? const [])
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList(),
        )) {
          result[source.id] = source;
        }
      }
    } on Object {
      /* Legacy transcripts have no source metadata. */
    }
    return List.unmodifiable(result.values);
  }
}
