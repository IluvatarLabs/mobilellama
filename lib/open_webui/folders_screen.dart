import 'package:flutter/material.dart';

import 'folders.dart';
import 'workspace.dart';

Future<void> moveWebUiChat(
  BuildContext context,
  WebUiWorkspace workspace,
  String chatId,
) async {
  final service = WebUiFolders(workspace.session);
  try {
    final folders = await service.list();
    if (!context.mounted) return;
    final id = await _chooseFolder(
      context,
      folders,
      title: 'Move chat',
      explanation: 'The server applies the destination folder’s current instructions to future requests. Moving clears the pin; moving into a folder also unarchives this chat.',
    );
    if (id == null) return;
    await service.moveChat(chatId, id.isEmpty ? null : id);
    await workspace.refresh();
    if (workspace.conversation?.id == chatId) {
      await workspace.refreshConversation();
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$error')));
    }
  }
}

Future<String?> _chooseFolder(
  BuildContext context,
  List<Map<String, dynamic>> folders, {
  required String title,
  String? excludedId,
  String? explanation,
}) {
  final excluded = <String>{if (excludedId != null) excludedId};
  var previous = -1;
  while (previous != excluded.length) {
    previous = excluded.length;
    for (final folder in folders) {
      if (excluded.contains(folder['parent_id'])) {
        excluded.add(folder['id'] as String);
      }
    }
  }
  String label(Map folder) {
    final names = [folder['name'] as String];
    final seen = {folder['id']};
    var parent = folder['parent_id'];
    while (parent != null && seen.add(parent)) {
      final ancestor = folders.where((f) => f['id'] == parent).firstOrNull;
      if (ancestor == null) break;
      names.insert(0, ancestor['name'] as String);
      parent = ancestor['parent_id'];
    }
    return names.join(' / ');
  }

  return showModalBottomSheet<String>(
    context: context,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => ListView(
      shrinkWrap: true,
      children: [
        ListTile(
          title: Text(title),
          subtitle: explanation == null ? null : Text(explanation),
        ),
        ListTile(
          title: Text(excludedId == null ? 'Unfiled' : 'Top level'),
          onTap: () => Navigator.pop(context, ''),
        ),
        for (final folder in folders)
          if (!excluded.contains(folder['id']) &&
              folder['permission'] != 'read')
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: Text(label(folder)),
              onTap: () => Navigator.pop(context, folder['id'] as String),
            ),
      ],
    ),
  );
}

class WebUiFoldersScreen extends StatefulWidget {
  const WebUiFoldersScreen({super.key, required this.workspace, this.folderId});
  final WebUiWorkspace workspace;
  final String? folderId;
  @override
  State<WebUiFoldersScreen> createState() => _WebUiFoldersScreenState();
}

class _WebUiFoldersScreenState extends State<WebUiFoldersScreen> {
  late final service = WebUiFolders(widget.workspace.session);
  List<Map<String, dynamic>> folders = [], chats = [];
  Map<String, dynamic>? detail;
  String? error;
  bool busy = true, more = false;
  int page = 1;
  bool get writable =>
      widget.workspace.foldersAvailable &&
      (widget.folderId == null || detail?['write_access'] == true);
  bool get owner =>
      detail?['user_id'] == widget.workspace.session.identity.userId;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load({bool next = false}) async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (!next) {
        folders = await service.list();
        detail = widget.folderId == null
            ? null
            : await service.get(widget.folderId!);
        chats = [];
        page = 0;
      }
      if (detail != null) {
        final result = await service.chats(detail!, page + 1);
        chats.addAll(result.chats);
        more = result.more;
        page++;
      }
    } catch (failure) {
      error = '$failure';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> edit({bool create = false}) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => _FolderEditor(
        service: service,
        id: create ? null : widget.folderId,
        parentId: create ? widget.folderId : null,
        name: create ? '' : detail?['name'] as String? ?? '',
        instructions: create
            ? ''
            : (detail?['data'] as Map?)?['system_prompt'] as String? ?? '',
      ),
    );
    if (saved == true && mounted) await load();
  }

  Future<void> action(String action) async {
    try {
      if (action == 'edit') {
        await edit();
        return;
      }
      if (action == 'move') {
        final id = await _chooseFolder(
          context,
          folders,
          title: 'Move folder',
          excludedId: widget.folderId,
        );
        if (id == null) return;
        await service.move(widget.folderId!, id.isEmpty ? null : id);
        await load();
      } else if (action == 'delete') {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Delete this folder and its subfolders?'),
            content: const Text(
              'All chats will be kept and moved to Unfiled. Folder instructions will no longer apply to their future requests.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Delete folders, keep chats'),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
        await service.deleteKeepingChats(widget.folderId!);
        await widget.workspace.refresh();
        await widget.workspace.refreshConversation();
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final children = folders
        .where(
          (f) =>
              f['parent_id'] == widget.folderId ||
              (widget.folderId == null &&
                  !folders.any((p) => p['id'] == f['parent_id'])),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(detail?['name'] as String? ?? 'Server folders'),
        actions: [
          IconButton(
            tooltip: 'Refresh folders',
            onPressed: busy ? null : load,
            icon: const Icon(Icons.refresh),
          ),
          if (writable)
            IconButton(
              tooltip: 'New folder',
              onPressed: busy ? null : () => edit(create: true),
              icon: const Icon(Icons.create_new_folder_outlined),
            ),
          if (detail != null && writable)
            PopupMenuButton<String>(
              onSelected: action,
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'edit',
                  child: Text('Folder settings'),
                ),
                if (owner)
                  const PopupMenuItem(
                    value: 'move',
                    child: Text('Move folder'),
                  ),
                if (owner)
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('Delete folder'),
                  ),
              ],
            ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: load,
        child: ListView(
          children: [
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (detail != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  ((detail!['data'] as Map?)?['system_prompt'] as String? ?? '')
                          .isEmpty
                      ? 'No instructions in this folder.'
                      : 'Server instructions for each request:\n${(detail!['data'] as Map)['system_prompt']}',
                ),
              ),
            if (detail != null && writable)
              ListTile(
                leading: const Icon(Icons.edit_square),
                title: const Text('New chat in this folder'),
                onTap: busy || widget.workspace.running
                    ? null
                    : () async {
                        await widget.workspace.open(null);
                        await widget.workspace.setDraftFolder(
                          widget.folderId!,
                          detail!['name'] as String,
                        );
                        if (context.mounted) Navigator.pop(context, true);
                      },
              ),
            for (final folder in children)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(folder['name'] as String),
                subtitle: folder['permission'] == null
                    ? null
                    : Text('Shared · ${folder['permission']}'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () async {
                  final opened = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => WebUiFoldersScreen(
                        workspace: widget.workspace,
                        folderId: folder['id'] as String,
                      ),
                    ),
                  );
                  if (!context.mounted) return;
                  if (opened == true) {
                    Navigator.pop(context, true);
                  } else {
                    await load();
                  }
                },
              ),
            for (final chat in chats)
              ListTile(
                title: Text(chat['title'] as String? ?? 'Chat'),
                subtitle: chat['readonly'] == true
                    ? const Text('Read only')
                    : null,
                onTap: () async {
                  await widget.workspace.open(chat['id'] as String);
                  if (context.mounted &&
                      widget.workspace.conversation?.id == chat['id']) {
                    Navigator.pop(context, true);
                  }
                },
              ),
            if (!busy && more)
              TextButton(
                onPressed: () => load(next: true),
                child: const Text('Load more chats'),
              ),
            if (!busy && children.isEmpty && chats.isEmpty && error == null)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No chats or subfolders here.'),
              ),
          ],
        ),
      ),
    );
  }
}

class _FolderEditor extends StatefulWidget {
  const _FolderEditor({
    required this.service,
    this.id,
    this.parentId,
    required this.name,
    required this.instructions,
  });
  final WebUiFolders service;
  final String? id, parentId;
  final String name, instructions;
  @override
  State<_FolderEditor> createState() => _FolderEditorState();
}

class _FolderEditorState extends State<_FolderEditor> {
  late final name = TextEditingController(text: widget.name);
  late final instructions = TextEditingController(text: widget.instructions);
  bool saving = false;
  String? error;
  @override
  void dispose() {
    name.dispose();
    instructions.dispose();
    super.dispose();
  }

  Future<void> save() async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.service.save(
        id: widget.id,
        parentId: widget.parentId,
        name: name.text,
        instructions: instructions.text,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (failure) {
      if (mounted) {
        setState(() {
          saving = false;
          error = '$failure';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !saving,
    child: AlertDialog(
      title: Text(widget.id == null ? 'New server folder' : 'Folder settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              enabled: !saving,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: instructions,
              enabled: !saving,
              minLines: 3,
              maxLines: 8,
              decoration: const InputDecoration(
                labelText: 'Folder instructions',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'The server applies these instructions on each request in this folder, including existing chats. Parent-folder instructions are not inherited.',
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
          onPressed: saving ? null : save,
          child: const Text('Save'),
        ),
      ],
    ),
  );
}
