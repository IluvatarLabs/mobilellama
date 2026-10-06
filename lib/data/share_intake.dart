import 'dart:io';

import 'package:flutter/services.dart';

final class SharedItem {
  SharedItem(Map<String, dynamic> json, this.root)
    : kind = json['kind'] as String,
      name = json['name'] as String? ?? 'Shared item',
      text = json['text'] as String?,
      file = json['file'] as String?,
      error = json['error'] as String?;
  final String root, kind, name;
  final String? text, file, error;
  Future<List<int>> readBytes() async {
    if (file == null ||
        file!.contains('/') ||
        file!.contains('\\') ||
        file == '.' ||
        file == '..') {
      throw const FormatException('Invalid shared file.');
    }
    final source = File('$root/$file');
    if (await source.length() > 8 * 1024 * 1024) {
      throw const FormatException('A shared file can be at most 8 MB.');
    }
    return source.readAsBytes();
  }
}

final class ShareIntake {
  ShareIntake(Map<String, dynamic> json)
    : id = json['id'] as String,
      items = (json['items'] as List)
          .map(
            (item) => SharedItem(
              Map<String, dynamic>.from(item as Map),
              json['root'] as String,
            ),
          )
          .toList();
  final String id;
  final List<SharedItem> items;
  static const _channel = MethodChannel('app.mobollama/intake');
  static Future<List<ShareIntake>> pending() async {
    try {
      final result = await _channel.invokeListMethod<dynamic>('pending');
      return (result ?? [])
          .map((item) => ShareIntake(Map<String, dynamic>.from(item as Map)))
          .toList();
    } on MissingPluginException {
      return [];
    }
  }

  static Future<void> removeId(String id) =>
      _channel.invokeMethod('remove', {'id': id});
  Future<void> remove() => removeId(id);
}
