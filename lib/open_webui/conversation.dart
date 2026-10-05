import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'client.dart';

/// The server owns this graph. Rendering and context follow parentId, never
/// insertion order or the server's optional flattened messages projection.
final class WebUiConversation {
  WebUiConversation(this.envelope) {
    final raw = chat['history'];
    if (raw is! Map || raw['messages'] is! Map) {
      throw const WebUiException(
        'This conversation has no readable message history.',
      );
    }
    history = Map<String, dynamic>.from(raw);
    nodes = {
      for (final entry in (history['messages'] as Map).entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: Map<String, dynamic>.from(entry.value as Map),
    };
  }
  final Map<String, dynamic> envelope;
  late final Map<String, dynamic> history;
  late final Map<String, Map<String, dynamic>> nodes;
  String get id => envelope['id'] as String;
  Map<String, dynamic> get chat =>
      Map<String, dynamic>.from(envelope['chat'] as Map);
  String get title =>
      chat['title'] as String? ?? envelope['title'] as String? ?? 'New chat';
  String? get tip {
    final selected = envelope['current_message_id'];
    return selected is String && nodes.containsKey(selected)
        ? selected
        : history['currentId'] as String?;
  }

  List<Map<String, dynamic>> branch({String? tipId}) {
    final result = <Map<String, dynamic>>[];
    final seen = <String>{};
    var current = tipId ?? tip;
    while (current != null) {
      if (!seen.add(current) || !nodes.containsKey(current)) {
        throw const WebUiException(
          'The server returned an incomplete conversation branch. Refresh before continuing.',
        );
      }
      final node = nodes[current]!;
      result.add({...node, 'id': current});
      current = node['parentId'] as String?;
    }
    return result.reversed.toList();
  }

  List<String> versions(String id) {
    final node = nodes[id];
    if (node == null) return const [];
    final parent = node['parentId'];
    final order = parent == null
        ? nodes.keys
        : (nodes[parent]?['childrenIds'] as List? ?? const [])
              .whereType<String>();
    return [
      for (final candidate in order)
        if (nodes[candidate]?['parentId'] == parent &&
            nodes[candidate]?['role'] == node['role'])
          candidate,
    ];
  }

  String deepest(String id) {
    final seen = <String>{};
    var current = id;
    while (seen.add(current)) {
      final children = (nodes[current]?['childrenIds'] as List? ?? const [])
          .whereType<String>()
          .where((id) => nodes[id]?['parentId'] == current)
          .toList();
      if (children.isEmpty) return current;
      current = children.last;
    }
    throw const WebUiException(
      'The server returned a cyclic conversation branch.',
    );
  }

  /// Parent/content ownership excludes children arrays so an additive sibling
  /// does not invalidate an explicitly selected continuation.
  String fingerprint(String? tipId) {
    Object? canonical(Object? value) => value is Map
        ? {
            for (final key in value.keys.cast<String>().toList()..sort())
              key: canonical(value[key]),
          }
        : value is List
        ? value.map(canonical).toList()
        : value;
    final path = tipId == null
        ? <Map<String, dynamic>>[]
        : branch(tipId: tipId);
    return sha256
        .convert(
          utf8.encode(
            jsonEncode(
              canonical([
                for (final node in path)
                  {
                    for (final key in [
                      'id',
                      'parentId',
                      'role',
                      'content',
                      'output',
                      'files',
                      'done',
                    ])
                      key: node[key],
                  },
              ]),
            ),
          ),
        )
        .toString();
  }
}

String webUiMessageText(Map node) {
  final output = node['output'];
  if (output is List) {
    final text = <String>[];
    for (final item in output.whereType<Map>()) {
      if (item['type'] != 'message' || item['content'] is! List) continue;
      for (final part in (item['content'] as List).whereType<Map>()) {
        if (part['type'] == 'output_text' && part['text'] is String) {
          text.add(part['text'] as String);
        }
      }
    }
    if (text.isNotEmpty) return text.join('\n');
  }
  return node['content'] is String ? node['content'] as String : '';
}

List<Map<String, dynamic>> webUiPendingCalls(Map node) {
  final output = (node['output'] as List? ?? const [])
      .whereType<Map>()
      .toList();
  final resolved = output
      .where((item) => item['type'] == 'function_call_output')
      .map((item) => item['call_id'])
      .toSet();
  return output
      .where(
        (item) =>
            item['type'] == 'function_call' &&
            {
              'pending',
              'queued',
              'requires_approval',
            }.contains(item['status']) &&
            item['approved'] != true &&
            !resolved.contains(item['call_id'] ?? item['id']),
      )
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}
