import 'document_attachment.dart';
import 'message.dart';

final class QueuedPrompt {
  QueuedPrompt({
    required this.id,
    required this.conversationId,
    required this.text,
    required List<String> imageReferences,
    required List<DocumentAttachment> documents,
    required this.createdAt,
  }) : imageReferences = List<String>.unmodifiable(imageReferences),
       documents = List<DocumentAttachment>.unmodifiable(documents);

  final String id;
  final String conversationId;
  final String text;
  final List<String> imageReferences;
  final List<DocumentAttachment> documents;
  final DateTime createdAt;

  QueuedPrompt copyWith({String? text}) => QueuedPrompt(
    id: id,
    conversationId: conversationId,
    text: text ?? this.text,
    imageReferences: imageReferences,
    documents: documents,
    createdAt: createdAt,
  );
}

final class QueuedPromptClaim {
  const QueuedPromptClaim({
    required this.prompt,
    required this.userMessage,
    required this.assistantMessage,
    required this.originalPosition,
  });

  final QueuedPrompt prompt;
  final Message userMessage;
  final Message assistantMessage;
  final int originalPosition;
}
