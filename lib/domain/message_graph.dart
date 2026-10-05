import 'message.dart';

/// Parent-linked message versions. Ordering only breaks ties between siblings;
/// context always follows the selected tip's ancestors.
final class MessageGraph {
  MessageGraph(Iterable<Message> messages)
    : nodes = Map.unmodifiable({
        for (final message in messages) message.id: message,
      }) {
    final complete = <String>{};
    for (final node in nodes.values) {
      final path = <String>{};
      Message? current = node;
      while (current != null && !complete.contains(current.id)) {
        if (!path.add(current.id)) {
          throw const FormatException('Message history contains a cycle.');
        }
        final parent = current.parentId == null
            ? null
            : nodes[current.parentId];
        if (current.parentId != null && parent == null) {
          throw const FormatException('Message history has a missing parent.');
        }
        if (parent != null && parent.conversationId != current.conversationId) {
          throw const FormatException(
            'Message parent belongs to another conversation.',
          );
        }
        if (current.position != (parent == null ? 0 : parent.position + 1) ||
            current.siblingOrder < 0) {
          throw const FormatException('Invalid message path position.');
        }
        current = parent;
      }
      complete.addAll(path);
    }
  }

  final Map<String, Message> nodes;
  List<Message> branch(String? tip) {
    if (tip == null) return const [];
    if (!nodes.containsKey(tip)) {
      throw const FormatException('The selected message version is missing.');
    }
    final reverse = <Message>[];
    var current = nodes[tip];
    while (current != null) {
      reverse.add(current);
      current = nodes[current.parentId];
    }
    return [
      for (final (index, node) in reverse.reversed.indexed)
        node.copyWith(position: index),
    ];
  }

  List<Message> siblings(String id) {
    final node = nodes[id];
    if (node == null) return const [];
    return nodes.values
        .where(
          (item) => item.parentId == node.parentId && item.role == node.role,
        )
        .toList()
      ..sort((a, b) {
        final order = a.siblingOrder.compareTo(b.siblingOrder);
        if (order != 0) return order;
        final created = a.createdAt.compareTo(b.createdAt);
        return created != 0 ? created : a.id.compareTo(b.id);
      });
  }
}
