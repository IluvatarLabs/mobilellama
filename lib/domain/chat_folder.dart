import 'dart:convert';

import 'package:crypto/crypto.dart';

final class ChatFolder {
  const ChatFolder({
    required this.id,
    required this.name,
    required this.instructions,
    required this.revision,
    this.deleted = false,
  });
  final String id, name, instructions;
  final int revision;
  final bool deleted;
  String get fingerprint => sha256
      .convert(
        utf8.encode(
          jsonEncode(
            {...toJson()}
              ..remove('revision')
              ..remove('id'),
          ),
        ),
      )
      .toString();
  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'instructions': instructions,
    'revision': revision,
    'deleted': deleted,
  };
  factory ChatFolder.fromJson(Map value) {
    if (value['id'] is! String ||
        (value['id'] as String).isEmpty ||
        value['name'] is! String ||
        (value['name'] as String).trim().isEmpty ||
        value['instructions'] is! String ||
        value['revision'] is! int ||
        (value['revision'] as int) < 0 ||
        value['deleted'] is! bool) {
      throw const FormatException('Invalid folder.');
    }
    return ChatFolder(
      id: value['id'] as String,
      name: value['name'] as String,
      instructions: value['instructions'] as String,
      revision: value['revision'] as int,
      deleted: value['deleted'] as bool,
    );
  }
}
