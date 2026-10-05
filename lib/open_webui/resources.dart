import '../domain/source_reference.dart';
import 'client.dart';

enum WebUiResourceKind { files, knowledge, prompts, skills, tools }

final class WebUiResourcePage {
  const WebUiResourcePage(this.items, this.hasMore);
  final List<Map<String, dynamic>> items;
  final bool hasMore;
}

final class WebUiResources {
  const WebUiResources(this.session);
  final WebUiSession session;

  Future<WebUiResourcePage> list(WebUiResourceKind kind, {int page = 1}) async {
    final lease = session.capture();
    final paged =
        kind == WebUiResourceKind.files || kind == WebUiResourceKind.knowledge;
    final path = switch (kind) {
      WebUiResourceKind.files => 'api/v1/files/',
      WebUiResourceKind.knowledge => 'api/v1/knowledge/',
      WebUiResourceKind.prompts => 'api/v1/prompts/',
      WebUiResourceKind.skills => 'api/v1/skills/',
      WebUiResourceKind.tools => 'api/v1/tools/',
    };
    final value = await session.client.request(
      'GET',
      path,
      lease: lease,
      query: paged
          ? {
              'page': '$page',
              if (kind == WebUiResourceKind.files) 'content': 'false',
            }
          : null,
    );
    final raw = paged && value is Map ? value['items'] : value;
    if (raw is! List) {
      throw const WebUiException('This server’s resource list is unavailable.');
    }
    final items = raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
    final perPage = kind == WebUiResourceKind.files ? 50 : 30;
    final total = value is Map ? value['total'] as int? : null;
    return WebUiResourcePage(
      items,
      paged &&
          (total != null ? page * perPage < total : items.length >= perPage),
    );
  }

  Future<Map<String, dynamic>> configuration() async {
    final value = await session.client.request(
      'GET',
      'api/config',
      lease: session.capture(),
    );
    return value is Map ? Map<String, dynamic>.from(value) : {};
  }

  bool supportsFeature(
    Map<String, dynamic> config,
    Map<String, dynamic>? model,
    String name,
  ) {
    final enabled = (config['features'] as Map?)?['enable_$name'] == true;
    final allowed =
        session.identity.role == 'admin' ||
        (session.identity.permissions['features'] as Map?)?[name] == true;
    final capability =
        ((model?['info'] as Map?)?['meta'] as Map?)?['capabilities'] as Map?;
    return enabled && allowed && capability?[name] != false;
  }

  Future<String> processingStatus(String id) async {
    final value = await session.client.request(
      'GET',
      'api/v1/files/${Uri.encodeComponent(id)}/process/status',
      lease: session.capture(),
    );
    return value is Map && value['status'] is String
        ? value['status'] as String
        : 'unavailable';
  }

  Future<String> sourceText(String fileId) async {
    final value = await session.client.request(
      'GET',
      'api/v1/files/${Uri.encodeComponent(fileId)}/data/content',
      lease: session.capture(),
    );
    final text = value is Map ? value['content'] : null;
    if (text is! String) {
      throw const WebUiException('This file has no readable extracted text.');
    }
    return text;
  }

  static String title(WebUiResourceKind kind, Map item) =>
      (item['name'] ??
              item['title'] ??
              item['filename'] ??
              item['command'] ??
              item['id'] ??
              kind.name)
          .toString();

  static Map<String, dynamic> reference(WebUiResourceKind kind, Map item) => {
    'id': item['id'],
    'name': title(kind, item),
    'type': kind == WebUiResourceKind.knowledge ? 'collection' : 'file',
    if (item['meta'] is Map && item['meta']['content_type'] is String)
      'content_type': item['meta']['content_type'],
  };

  /// Server-provided knowledge/search sources are separate from model text.
  /// Private file IDs stay scoped to this account's authenticated source viewer.
  static List<SourceReference> sources(Map node) {
    final result = <String, SourceReference>{};
    for (final group
        in (node['sources'] as List? ?? const []).whereType<Map>()) {
      final source = group['source'] is Map ? group['source'] as Map : const {};
      final metadata = (group['metadata'] as List? ?? const [])
          .whereType<Map>()
          .toList();
      final documents = group['document'] as List? ?? const [];
      for (
        var index = 0;
        index < (metadata.isEmpty ? 1 : metadata.length);
        index++
      ) {
        final meta = metadata.isEmpty ? const {} : metadata[index];
        final fileId =
            meta['file_id'] ?? (source['type'] == 'file' ? source['id'] : null);
        final candidate = meta['url'] ?? meta['source'] ?? source['url'];
        final uri = candidate is String ? Uri.tryParse(candidate) : null;
        final url =
            uri != null &&
                {'http', 'https'}.contains(uri.scheme) &&
                uri.host.isNotEmpty &&
                uri.userInfo.isEmpty
            ? uri.toString()
            : null;
        if (fileId is! String && url == null) continue;
        final key = fileId is String && fileId.isNotEmpty
            ? 'file:$fileId'
            : 'url:$url';
        final text = index < documents.length && documents[index] is String
            ? documents[index] as String
            : null;
        result[key] = SourceReference(
          id: key,
          title: (meta['name'] ?? source['name'] ?? uri?.host ?? 'Source')
              .toString(),
          fileId: fileId is String && fileId.isNotEmpty ? fileId : null,
          url: fileId is String && fileId.isNotEmpty ? null : url,
          excerpt: text == null
              ? null
              : text.substring(0, text.length.clamp(0, 4000)),
        );
      }
    }
    for (final source in SourceReference.fromProviderItems(
      (node['output'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList(),
    )) {
      final key = source.fileId != null
          ? 'file:${source.fileId}'
          : source.url != null
          ? 'url:${source.url}'
          : source.id;
      result.putIfAbsent(key, () => source);
    }
    return result.values.toList();
  }
}
