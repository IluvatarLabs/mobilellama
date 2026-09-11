class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'arguments': arguments,
  };

  factory ToolCall.fromJson(Map<String, Object?> json) {
    final rawArguments = json['arguments'];
    return ToolCall(
      id: json['id']! as String,
      name: json['name']! as String,
      arguments: rawArguments is Map
          ? Map<String, Object?>.from(rawArguments)
          : const <String, Object?>{},
    );
  }
}

class ToolResult {
  const ToolResult({
    required this.id,
    required this.toolCallId,
    required this.content,
    this.isError = false,
  });

  final String id;
  final String toolCallId;
  final String content;
  final bool isError;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'toolCallId': toolCallId,
    'content': content,
    'isError': isError,
  };

  factory ToolResult.fromJson(Map<String, Object?> json) => ToolResult(
    id: json['id']! as String,
    toolCallId: json['toolCallId']! as String,
    content: json['content']! as String,
    isError: json['isError'] as bool? ?? false,
  );
}
