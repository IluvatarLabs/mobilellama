import 'package:flutter/material.dart';

import '../domain/chat_folder.dart';
import 'chat_actions.dart';
import 'chat_controller.dart';
import 'history.dart';

Future<void> moveChatToFolder(
  BuildContext context,
  ChatController controller,
  String chatId,
) async {
  final selection = await showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => ListView(
      shrinkWrap: true,
      children: [
        const ListTile(
          title: Text('Move to folder'),
          subtitle: Text(
            'Moving a chat keeps its existing instructions and draft.',
          ),
        ),
        ListTile(
          leading: const Icon(Icons.inbox_outlined),
          title: const Text('Unfiled'),
          onTap: () => Navigator.pop(context, ''),
        ),
        for (final folder in controller.folders)
          ListTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(folder.name),
            onTap: () => Navigator.pop(context, folder.id),
          ),
      ],
    ),
  );
  if (selection == null) return;
  try {
    await controller.moveConversationToFolder(
      chatId,
      selection.isEmpty ? null : selection,
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

class FoldersPage extends StatelessWidget {
  const FoldersPage({super.key, required this.controller});
  final ChatController controller;
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: const Text('Folders'),
        actions: [
          IconButton(
            tooltip: 'New folder',
            onPressed: () => _editFolder(context, controller),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
        ],
      ),
      body: ListView(
        children: [
          for (final folder in <ChatFolder?>[null, ...controller.folders])
            ListTile(
              leading: Icon(
                folder == null ? Icons.inbox_outlined : Icons.folder_outlined,
              ),
              title: Text(folder?.name ?? 'Unfiled'),
              subtitle: Text(
                '${controller.history.where((c) => folder == null ? controller.folderById(c.folderId) == null : c.folderId == folder.id).length} chats',
              ),
              onTap: () async {
                final opened = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FolderChatsPage(
                      controller: controller,
                      folderId: folder?.id,
                    ),
                  ),
                );
                if (opened == true && context.mounted) {
                  Navigator.pop(context, true);
                }
              },
            ),
        ],
      ),
    ),
  );
}

class FolderChatsPage extends StatefulWidget {
  const FolderChatsPage({super.key, required this.controller, this.folderId});
  final ChatController controller;
  final String? folderId;
  @override
  State<FolderChatsPage> createState() => _FolderChatsPageState();
}

class _FolderChatsPageState extends State<FolderChatsPage> {
  String query = '';
  bool archived = false;
  final search = TextEditingController();
  Map<String, String?>? matches;
  int generation = 0;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> find(String value) async {
    final token = ++generation;
    setState(() => query = value);
    final results = value.trim().isEmpty
        ? null
        : {
            for (final r in await widget.controller.searchConversations(value))
              r.conversation.id: r.messageId,
          };
    if (mounted && token == generation) setState(() => matches = results);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final c = widget.controller;
      final folder = c.folderById(widget.folderId);
      final chats = c.history
          .where(
            (chat) =>
                (folder == null
                    ? c.folderById(chat.folderId) == null
                    : chat.folderId == folder.id) &&
                chat.isArchived == archived &&
                (matches == null || matches!.containsKey(chat.id)),
          )
          .toList();
      return Scaffold(
        appBar: AppBar(
          title: Text(folder?.name ?? 'Unfiled'),
          actions: [
            if (folder != null)
              PopupMenuButton<String>(
                tooltip: 'Folder actions',
                onSelected: (value) async {
                  if (value == 'edit') {
                    await _editFolder(context, c, folder);
                    return;
                  }
                  if (value == 'delete' &&
                      await confirmDelete(
                        context,
                        title: 'Delete “${folder.name}”?',
                        message: 'Its chats will be kept in Unfiled. Existing chat instructions will stay as they are.',
                      )) {
                    await c.deleteFolder(folder.id);
                    if (context.mounted) Navigator.pop(context);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('Edit folder')),
                  PopupMenuItem(value: 'delete', child: Text('Delete folder')),
                ],
              ),
            IconButton(
              tooltip: 'New chat in folder',
              onPressed: () async {
                await c.newConversationInFolder(folder?.id);
                if (context.mounted) Navigator.pop(context, true);
              },
              icon: const Icon(Icons.edit_square),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: TextField(
                controller: search,
                onChanged: find,
                decoration: const InputDecoration(
                  hintText: 'Search in this folder',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('Archived chats'),
              value: archived,
              onChanged: (v) => setState(() => archived = v),
            ),
            Expanded(
              child: chats.isEmpty
                  ? const Center(child: Text('No chats here.'))
                  : ListView.builder(
                      itemCount: chats.length,
                      itemBuilder: (context, i) => ChatHistoryRow(
                        chat: chats[i],
                        controller: c,
                        onTap: () async {
                          await c.openConversation(chats[i].id);
                          if (matches?[chats[i].id] case final messageId?) {
                            await c.viewVersion(messageId);
                          }
                          if (context.mounted &&
                              c.conversation?.id == chats[i].id) {
                            Navigator.pop(context, true);
                          }
                        },
                      ),
                    ),
            ),
          ],
        ),
      );
    },
  );
}

Future<void> _editFolder(
  BuildContext context,
  ChatController controller, [
  ChatFolder? folder,
]) async {
  await showDialog<void>(
    context: context,
    builder: (_) => _FolderEditor(controller: controller, folder: folder),
  );
}

class _FolderEditor extends StatefulWidget {
  const _FolderEditor({required this.controller, this.folder});
  final ChatController controller;
  final ChatFolder? folder;
  @override
  State<_FolderEditor> createState() => _FolderEditorState();
}

class _FolderEditorState extends State<_FolderEditor> {
  late final name = TextEditingController(text: widget.folder?.name);
  late final instructions = TextEditingController(
    text: widget.folder?.instructions,
  );
  String? error;
  bool saving = false;
  @override
  void dispose() {
    name.dispose();
    instructions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.folder == null ? 'New folder' : 'Edit folder'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: name,
            autofocus: true,
            maxLength: 80,
            textCapitalization: TextCapitalization.sentences,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          TextField(
            controller: instructions,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Instructions (optional)',
              alignLabelWithHint: true,
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Instructions apply to future chats. Existing chats keep their saved instructions. Leave this empty to use the server profile’s default.',
            ),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: saving
            ? null
            : () async {
                setState(() => saving = true);
                try {
                  await widget.controller.saveFolder(
                    id: widget.folder?.id,
                    name: name.text,
                    instructions: instructions.text,
                  );
                  if (context.mounted) Navigator.pop(context);
                } catch (e) {
                  if (mounted) {
                    setState(() {
                      error = '$e';
                      saving = false;
                    });
                  }
                }
              },
        child: const Text('Save'),
      ),
    ],
  );
}
