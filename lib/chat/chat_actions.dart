import 'package:flutter/material.dart';

import '../domain/conversation.dart';
import '../ui/design.dart';
import '../settings/settings_sheet.dart';
import 'chat_controller.dart';
import 'share_actions.dart';

Future<bool> confirmDelete(
  BuildContext context, {
  required String title,
  required String message,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    ) ??
    false;

void showChatError(BuildContext context, ChatController controller) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        controller.errorMessage ?? 'Wait for the current action to finish.',
      ),
    ),
  );
}

Future<void> showChatActions(
  BuildContext context,
  ChatController controller,
  Conversation chat, {
  VoidCallback? onFind,
}) async {
  final action = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    barrierColor: Design.ink.withValues(alpha: .70),
    builder: (context) => SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            const SheetHeading(title: 'Chat', closeLabel: 'Close chat actions'),
            for (final item in <(String, String)>[
              if (controller.conversation?.id == chat.id && onFind != null)
                ('find', 'Find in chat'),
              ('rename', 'Rename'),
              ('pin', chat.isPinned ? 'Unpin' : 'Pin'),
              ('archive', chat.isArchived ? 'Unarchive' : 'Archive'),
              if (controller.conversation?.id == chat.id)
                ('settings', 'Chat settings'),
              ('share', 'Share conversation'),
              ('delete', 'Delete'),
            ])
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: Design.line(context, .12)),
                  ),
                ),
                child: ListTile(
                  minTileHeight: 62,
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    item.$2,
                    style: TextStyle(
                      fontSize: 17,
                      color: item.$1 == 'delete'
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                  onTap: () => Navigator.pop(context, item.$1),
                ),
              ),
          ],
        ),
      ),
    ),
  );
  if (!context.mounted || action == null) return;
  if (action == 'find') {
    onFind?.call();
    return;
  }
  if (action == 'settings') {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsSheet(
          controller: controller,
          section: SettingsSection.conversation,
        ),
      ),
    );
    return;
  }
  if (action == 'share') {
    if (controller.isConversationRunning(chat.id)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Wait for this response to finish before sharing.'),
        ),
      );
      return;
    }
    try {
      final markdown = await controller.conversationMarkdown(chat.id);
      if (!context.mounted) return;
      await shareConversationMarkdown(
        context,
        title: chat.title,
        markdown: markdown,
      );
    } on Object {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This conversation could not be prepared to share.'),
          ),
        );
      }
    }
    return;
  }
  bool success = true;
  switch (action) {
    case 'rename':
      final name = await showDialog<String>(
        context: context,
        builder: (_) => _RenameDialog(title: chat.title),
      );
      if (name != null) {
        success = await controller.renameConversation(chat.id, name);
      }
    case 'pin':
      success = await controller.pinConversation(chat.id, !chat.isPinned);
    case 'archive':
      success = await controller.archiveConversation(chat.id, !chat.isArchived);
    case 'delete':
      if (await confirmDelete(
        context,
        title: 'Delete “${chat.title}”?',
        message: 'This chat, its unsent draft, and its stored attachments will be permanently deleted.',
      )) {
        success = await controller.deleteConversation(chat.id);
      }
  }
  if (context.mounted && (!success || controller.errorMessage != null)) {
    showChatError(context, controller);
  }
}

class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.title});
  final String title;
  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final _name = TextEditingController(text: widget.title);
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final title = _name.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Enter a chat name.');
      return;
    }
    Navigator.pop(context, title);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Rename chat'),
    content: TextField(
      controller: _name,
      autofocus: true,
      maxLines: 3,
      minLines: 1,
      decoration: InputDecoration(labelText: 'Chat name', errorText: _error),
      onSubmitted: (_) => _save(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      TextButton(onPressed: _save, child: const Text('Save')),
    ],
  );
}
