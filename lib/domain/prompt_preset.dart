import 'dart:convert';

import 'generation_options.dart';

/// A saved set of chat settings, copied into a chat only when applied.
final class PromptPreset {
  PromptPreset({
    required this.id,
    required String name,
    required this.systemPrompt,
    required this.generationOptions,
  }) : name = name.trim() {
    if (id.isEmpty || this.name.isEmpty || this.name.length > 80) {
      throw const FormatException('Give the preset a name of 1–80 characters.');
    }
    if (utf8.encode(systemPrompt).length > 64 * 1024) {
      throw const FormatException('Instructions can be at most 64 KB.');
    }
    generationOptions.validate();
  }

  final String id;
  final String name;
  final String systemPrompt;
  final GenerationOptions generationOptions;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'systemPrompt': systemPrompt,
    'options': generationOptions.toOllamaJson(),
  };

  factory PromptPreset.fromJson(Map<String, Object?> json) => PromptPreset(
    id: json['id'] as String,
    name: json['name'] as String,
    systemPrompt: json['systemPrompt'] as String,
    generationOptions: GenerationOptions.fromJson(
      Map<String, Object?>.from(json['options'] as Map),
    ),
  );
}
