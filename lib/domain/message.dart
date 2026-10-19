import 'document_attachment.dart';
import 'source_reference.dart';
import 'tool_call.dart';

enum MessageRole { system, user, assistant, tool }

enum MessageStatus { queued, streaming, complete, partial, interrupted, failed }

class Message {
  const Message({
    required this.id,
    required this.conversationId,
    required this.position,
    required this.role,
    required this.status,
    required this.content,
    required this.createdAt,
    required this.updatedAt,
    this.parentId,
    this.siblingOrder = 0,
    this.reasoning,
    this.providerTranscriptJson,
    this.imageReferences = const <String>[],
    this.documents = const <DocumentAttachment>[],
    this.toolCalls = const <ToolCall>[],
    this.toolResults = const <ToolResult>[],
  });

  final String id;
  final String conversationId;
  final int position;
  final String? parentId;
  final int siblingOrder;
  final MessageRole role;
  final MessageStatus status;
  final String content;
  final String? reasoning;
  final String? providerTranscriptJson;
  final List<String> imageReferences;
  final List<DocumentAttachment> documents;
  final List<ToolCall> toolCalls;
  final List<ToolResult> toolResults;
  final DateTime createdAt;
  final DateTime updatedAt;

  List<SourceReference> get sources =>
      SourceReference.fromTranscript(providerTranscriptJson);

  Message copyWith({
    String? id,
    Object? parentId = _notProvided,
    int? siblingOrder,
    int? position,
    MessageStatus? status,
    String? content,
    Object? reasoning = _notProvided,
    Object? providerTranscriptJson = _notProvided,
    List<String>? imageReferences,
    List<DocumentAttachment>? documents,
    List<ToolCall>? toolCalls,
    List<ToolResult>? toolResults,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => Message(
    id: id ?? this.id,
    parentId: identical(parentId, _notProvided)
        ? this.parentId
        : parentId as String?,
    siblingOrder: siblingOrder ?? this.siblingOrder,
    conversationId: conversationId,
    position: position ?? this.position,
    role: role,
    status: status ?? this.status,
    content: content ?? this.content,
    reasoning: identical(reasoning, _notProvided)
        ? this.reasoning
        : reasoning as String?,
    providerTranscriptJson: identical(providerTranscriptJson, _notProvided)
        ? this.providerTranscriptJson
        : providerTranscriptJson as String?,
    imageReferences: imageReferences ?? this.imageReferences,
    documents: documents ?? this.documents,
    toolCalls: toolCalls ?? this.toolCalls,
    toolResults: toolResults ?? this.toolResults,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  static const Object _notProvided = Object();
}
