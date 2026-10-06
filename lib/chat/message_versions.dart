import 'package:flutter/material.dart';

import '../domain/message.dart';
import 'chat_controller.dart';

class MessageVersions extends StatelessWidget {
  const MessageVersions({
    super.key,
    required this.controller,
    required this.messageId,
  });
  final ChatController controller;
  final String messageId;
  @override
  Widget build(BuildContext context) => FutureBuilder<List<Message>>(
    future: controller.versionsOf(messageId),
    builder: (context, snapshot) {
      final versions = snapshot.data ?? const [];
      if (versions.length < 2) return const SizedBox.shrink();
      final index = versions.indexWhere((m) => m.id == messageId);
      if (index < 0) return const SizedBox.shrink();
      final enabled =
          controller.canChangeContext &&
          !controller.isConversationRunning(controller.conversation!.id);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: 'Previous version',
            onPressed: enabled && index > 0
                ? () => controller.viewVersion(versions[index - 1].id)
                : null,
            icon: const Icon(Icons.chevron_left, size: 20),
          ),
          Semantics(
            label: 'Version ${index + 1} of ${versions.length}',
            child: Text(
              '${index + 1}/${versions.length}',
              style: Theme.of(context).textTheme.labelMedium,
            ),
          ),
          IconButton(
            tooltip: 'Next version',
            onPressed: enabled && index < versions.length - 1
                ? () => controller.viewVersion(versions[index + 1].id)
                : null,
            icon: const Icon(Icons.chevron_right, size: 20),
          ),
        ],
      );
    },
  );
}

class VersionPreviewNotice extends StatelessWidget {
  const VersionPreviewNotice({super.key, required this.controller});
  final ChatController controller;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainerHigh,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Viewing an earlier version',
            style: Theme.of(context).textTheme.labelLarge,
          ),
          const Text('Choose this version before sending a follow-up.'),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: controller.returnToContinuation,
                child: const Text('Back to selected branch'),
              ),
              TextButton(
                onPressed: controller.continueViewedVersion,
                child: const Text('Continue from this version'),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class DraftBranchNotice extends StatelessWidget {
  const DraftBranchNotice({super.key, required this.controller});
  final ChatController controller;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Your draft belongs to another answer version.'),
        Wrap(
          children: [
            TextButton(
              onPressed: controller.viewDraftBranch,
              child: const Text('View original branch'),
            ),
            TextButton(
              onPressed: controller.useDraftWithSelectedBranch,
              child: const Text('Use with selected branch'),
            ),
          ],
        ),
      ],
    ),
  );
}
