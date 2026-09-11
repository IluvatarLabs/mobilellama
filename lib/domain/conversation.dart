import 'generation_options.dart';
import 'message.dart';

class Conversation {
  const Conversation({
    required this.id,
    required this.serverProfileId,
    required this.title,
    required this.selectedModel,
    required this.systemPrompt,
    required this.createdAt,
    required this.updatedAt,
    this.generationOptions = const GenerationOptions(),
    this.isPinned = false,
    this.isArchived = false,
    this.isRenamed = false,
  });

  final String id;
  final String serverProfileId;
  final String title;
  final String selectedModel;
  final String systemPrompt;
  final DateTime createdAt;
  final DateTime updatedAt;
  final GenerationOptions generationOptions;
  final bool isPinned;
  final bool isArchived;
  final bool isRenamed;
}

class ConversationThread {
  const ConversationThread({
    required this.conversation,
    required this.messages,
  });

  final Conversation conversation;
  final List<Message> messages;
}

String titleFromFirstUserText(String text, {int maximumLength = 60}) {
  if (maximumLength < 1) {
    throw ArgumentError.value(
      maximumLength,
      'maximumLength',
      'must be positive',
    );
  }

  final normalized = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (normalized.isEmpty) return 'New chat';
  final codePoints = normalized.runes.toList(growable: false);
  if (codePoints.length <= maximumLength) return normalized;
  final prefix = String.fromCharCodes(codePoints.take(maximumLength - 1));
  return '${prefix.trimRight()}…';
}
