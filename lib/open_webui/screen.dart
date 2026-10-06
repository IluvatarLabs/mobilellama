import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';

import '../chat/composer.dart';
import '../chat/transcript.dart';
import '../domain/source_reference.dart';
import 'conversation.dart';
import 'run.dart';
import 'socket.dart';
import 'workspace.dart';
import 'resource_picker.dart';
import 'resources.dart';
import 'artifacts.dart';
import 'export.dart';
import 'temporary_screen.dart';
import 'folders_screen.dart';
import '../chat/share_actions.dart';
import '../chat/find_in_chat.dart';

class WebUiScreen extends StatefulWidget {
  const WebUiScreen({super.key, required this.workspace});
  final WebUiWorkspace workspace;
  @override
  State<WebUiScreen> createState() => _WebUiScreenState();
}

class _WebUiScreenState extends State<WebUiScreen> with WidgetsBindingObserver {
  final _editor = TextEditingController(), _search = TextEditingController();
  final _focus = FocusNode();
  final _find = ChatFindController();
  StreamSubscription<WebUiEvent>? _events;
  Timer? _searchTimer;
  WebUiWorkspace get w => widget.workspace;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    w.session.addListener(_accountChanged);
    _events = w.socket.events.listen(_socketEvent);
    unawaited(
      w.initialize().catchError((Object error) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'This account could not be opened. Sign in again to retry.',
              ),
            ),
          );
        }
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      w.setForeground(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _searchTimer?.cancel();
    unawaited(_events?.cancel());
    w.session.removeListener(_accountChanged);
    _find.dispose();
    _editor.dispose();
    _search.dispose();
    _focus.dispose();
    unawaited(w.flushDraft().whenComplete(w.dispose));
    super.dispose();
  }

  void _accountChanged() {
    if (!mounted || !w.locked) return;
    final ownRoute = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && ownRoute?.isActive == true) {
        Navigator.of(context).popUntil((route) => route == ownRoute);
      }
    });
  }

  Future<void> _socketEvent(WebUiEvent event) async {
    if (!mounted ||
        w.locked ||
        event.reply == null ||
        event.chatId != (w.conversation?.id ?? w.run?.chatId)) {
      return;
    }
    final data = event.data is Map ? event.data as Map : const {};
    Object? result;
    if (event.type == 'confirmation') {
      result =
          await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text(
                data['title'] as String? ?? 'Server tool confirmation',
              ),
              content: SingleChildScrollView(
                child: Text(
                  data['message'] as String? ??
                      'The server is waiting for your decision.',
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Deny'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Allow'),
                ),
              ],
            ),
          ) ??
          false;
    } else if (event.type == 'input') {
      result = await _textDialog(
        data['title'] as String? ?? 'Server tool input',
        data['value'] as String? ?? '',
        description: data['message'] as String?,
      );
      result ??= false;
    } else if (event.type == 'execute' || event.type == 'execute:tool') {
      result = {
        'error': 'Client-side execution is unavailable in MobileLlama. Configure a server-executed tool.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This tool requires browser-side execution and is unavailable on this device.',
          ),
        ),
      );
    } else if (event.type == 'request:user_input') {
      result =
          await answerServerQuestions(
            context,
            data['questions'],
            allowOther: data['allow_other'] != false,
          ) ??
          {'status': 'cancelled', 'answers': {}};
    } else {
      return;
    }
    if (!mounted || w.locked) return;
    try {
      event.reply!(result);
    } on Object {
      /* The server session expired while its dialog was open. */
    }
  }

  Future<String?> _textDialog(
    String title,
    String initial, {
    String? description,
  }) async {
    final field = TextEditingController(text: initial);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (description != null) Text(description),
            TextField(
              controller: field,
              autofocus: true,
              minLines: 1,
              maxLines: 6,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, field.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    field.dispose();
    return value;
  }

  Future<void> _action(String id, String action) async {
    if (action == 'folder') {
      await moveWebUiChat(context, w, id);
      return;
    }
    if (action == 'rename') {
      final title = await _textDialog(
        'Rename chat',
        w.history.where((item) => item['id'] == id).firstOrNull?['title']
                as String? ??
            'Chat',
      );
      if (title == null || title.trim().isEmpty) return;
      await w.mutate(id, action, title: title.trim());
    } else if (action == 'delete') {
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delete server chat?'),
          content: const Text(
            'This deletes the conversation from your server and its local cache. It cannot be undone here.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (accepted == true) await w.mutate(id, action);
    } else {
      await w.mutate(id, action);
    }
  }

  Future<void> _signOut() async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out of this account?'),
        content: const Text(
          'This removes this account’s cached chats, files, unsent drafts, queued prompts, pending requests, and saved credentials from this device. Its history remains on the server. Active server work may continue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    try {
      await w.accounts.signOut(w.session);
      if (mounted) Navigator.pop(context);
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Local sign-out could not finish. Return to Connections and retry clearing this account.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _chooseModel() async {
    final value = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        expand: false,
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            const ListTile(title: Text('Model')),
            for (final model in w.models)
              ListTile(
                title: Text(model['name'] as String? ?? model['id'] as String),
                subtitle: Text(model['id'] as String),
                selected: w.model == model['id'],
                onTap: () => Navigator.pop(context, model['id'] as String),
              ),
          ],
        ),
      ),
    );
    if (value != null) await w.selectModel(value);
  }

  void _quote(String text) {
    final value = _editor.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final quote =
        '${selection.start > 0 ? '\n\n' : ''}${text.split('\n').map((line) => '> $line').join('\n')}\n\n';
    final next = value.text.replaceRange(selection.start, selection.end, quote);
    if (utf8.encode(next).length > 64 * 1024) return;
    _editor.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(
        offset: selection.start + quote.length,
      ),
    );
    _focus.requestFocus();
  }

  void _insert(String text, {bool replaceDollar = false}) {
    final value = _editor.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    var start = selection.start;
    if (replaceDollar) {
      final match = RegExp(r'\$[^\s]*$')
          .firstMatch(value.text.substring(0, start));
      if (match != null) start = match.start;
    }
    final next = value.text.replaceRange(start, selection.end, text);
    if (utf8.encode(next).length > 64 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This insertion exceeds the 64 KB message limit.'),
        ),
      );
      return;
    }
    _editor.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
    );
    _focus.requestFocus();
  }

  Future<void> _pickResource(WebUiResourceKind kind, {bool mention = false}) =>
      showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (context) => WebUiResourcePicker(
          workspace: w,
          kind: kind,
          mention: mention,
          onInsert: (text) => _insert(text, replaceDollar: mention),
        ),
      );
  Future<void> _pickFile({ImageSource? imageSource}) async {
    final scope = w.scope;
    try {
      final file = imageSource == null
          ? await openFile()
          : await ImagePicker().pickImage(
              source: imageSource,
              maxWidth: 2048,
              maxHeight: 2048,
              imageQuality: 85,
            );
      if (file == null || !mounted || w.locked || w.scope != scope) return;
      if (await file.length() > 8 * 1024 * 1024) {
        throw const FormatException('Choose a file of up to 8 MB.');
      }
      final bytes = await file.readAsBytes();
      if (!mounted || w.scope != scope) return;
      await w.addFile(file.name, bytes);
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              error is FormatException
                  ? error.message
                  : 'This file could not be added. Your draft is retained.',
            ),
          ),
        );
      }
    }
  }

  Future<void> _features() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    builder: (context) => AnimatedBuilder(
      animation: w,
      builder: (context, _) {
        final model = w.models
            .where((item) => item['id'] == w.model)
            .firstOrNull;
        final flags = w.resources['features'] as Map? ?? {};
        return SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              const ListTile(
                title: Text('Server features'),
                subtitle: Text(
                  'Availability depends on your server, account permissions, and model.',
                ),
              ),
              for (final feature in ['web_search', 'image_generation'])
                SwitchListTile(
                  title: Text(
                    feature == 'web_search' ? 'Web search' : 'Image generation',
                  ),
                  subtitle:
                      w.serverResources.supportsFeature(
                        w.serverConfiguration,
                        model,
                        feature,
                      )
                      ? null
                      : const Text('Unavailable for this connection or model'),
                  value: flags[feature] == true,
                  onChanged:
                      !w.serverResources.supportsFeature(
                        w.serverConfiguration,
                        model,
                        feature,
                      )
                      ? null
                      : (enabled) async {
                          if (feature == 'web_search' &&
                              enabled &&
                              (w.serverConfiguration['features']
                                      as Map?)?['enable_web_search_confirmation'] ==
                                  true) {
                            final agreed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('Enable web search?'),
                                content: Text(
                                  (w.serverConfiguration['features']
                                              as Map?)?['web_search_confirmation_content']
                                          as String? ??
                                      'Queries may be sent to the search service configured by your server.',
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('Cancel'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('Enable'),
                                  ),
                                ],
                              ),
                            );
                            if (agreed != true) return;
                          }
                          await w.setFeature(feature, enabled);
                        },
                ),
              if ((w.serverConfiguration['features']
                      as Map?)?['enable_tool_permissions'] ==
                  true)
                SwitchListTile(
                  title: const Text('Ask before tool calls'),
                  subtitle: const Text('Uses the server’s approval mechanism.'),
                  value:
                      (w.resources['params'] as Map?)?['tool_approval_mode'] ==
                      'ask',
                  onChanged: w.setToolApproval,
                ),
            ],
          ),
        );
      },
    ),
  );

  Widget _versionFooter(TranscriptMessageView message) {
    final versions = w.versionsOf(message.id);
    final index = versions.indexOf(message.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        WebUiArtifacts(session: w.session, node: w.messageNode(message.id)),
        if (versions.length > 1 && index >= 0)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: 'Previous version',
                onPressed: w.canBrowseVersions && index > 0
                    ? () => w.viewVersion(versions[index - 1])
                    : null,
                icon: const Icon(Icons.chevron_left, size: 20),
              ),
              Semantics(
                label: 'Version ${index + 1} of ${versions.length}',
                child: Text('${index + 1}/${versions.length}'),
              ),
              IconButton(
                tooltip: 'Next version',
                onPressed: w.canBrowseVersions && index < versions.length - 1
                    ? () => w.viewVersion(versions[index + 1])
                    : null,
                icon: const Icon(Icons.chevron_right, size: 20),
              ),
            ],
          ),
      ],
    );
  }

  Widget _versionNotice() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w.previewingVersion
              ? 'Viewing an earlier version'
              : 'Next message follows the selected version',
        ),
        if (w.previewingVersion)
          Wrap(
            children: [
              TextButton(
                onPressed: w.returnToContinuation,
                child: const Text('Back to selected branch'),
              ),
              if (!w.readOnlyConversation)
                TextButton(
                  onPressed: w.canRevise ? w.continueViewedVersion : null,
                  child: const Text('Continue from this version'),
                ),
            ],
          )
        else
          TextButton(
            onPressed: w.canRevise ? w.adoptContinuation : null,
            child: const Text('Use server’s current branch'),
          ),
      ],
    ),
  );

  Widget _selectedResources() {
    final uploads = w.uploads;
    final files = (w.resources['files'] as List? ?? []).whereType<Map>().where(
      (file) => !uploads.any((upload) => upload['remoteId'] == file['id']),
    );
    final chips = <Widget>[
      if (w.conversation == null && w.resources['folderId'] != null)
        InputChip(
          avatar: const Icon(Icons.folder_outlined, size: 18),
          label: Text(
            'Folder: ${w.resources['folderName'] ?? 'Selected folder'}',
          ),
          onDeleted: w.running ? null : () => w.setDraftFolder(null, null),
        ),
      for (final file in files)
        InputChip(
          label: Text((file['name'] ?? file['id']).toString()),
          onDeleted: () => w.setResource(
            file['type'] == 'collection'
                ? WebUiResourceKind.knowledge
                : WebUiResourceKind.files,
            Map<String, dynamic>.from(file),
            false,
          ),
        ),
      for (final kind in [WebUiResourceKind.skills, WebUiResourceKind.tools])
        for (final id
            in (w.resources[kind == WebUiResourceKind.skills
                        ? 'skill_ids'
                        : 'tool_ids']
                    as List? ??
                []))
          InputChip(
            label: Text(
              '${kind == WebUiResourceKind.skills ? 'Skill' : 'Tool'}: $id',
            ),
            onDeleted: () => w.setResource(kind, {'id': id}, false),
          ),
      for (final entry in (w.resources['features'] as Map? ?? {}).entries.where(
        (entry) => entry.value == true,
      ))
        InputChip(
          label: Text(
            entry.key == 'web_search' ? 'Web search' : 'Image generation',
          ),
          onDeleted: () => w.setFeature(entry.key as String, false),
        ),
      for (final upload in uploads)
        InputChip(
          avatar: Icon(
            upload['state'] == 'ready'
                ? Icons.check
                : upload['state'] == 'failed'
                ? Icons.error_outline
                : Icons.hourglass_top,
            size: 18,
          ),
          label: Text('${upload['name']} · ${upload['state']}'),
          tooltip: upload['error'] as String?,
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            useSafeArea: true,
            builder: (context) => Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    upload['name'] as String,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    upload['error'] as String? ??
                        (upload['state'] == 'ready'
                            ? 'Ready to use. Removing it here does not delete the server copy.'
                            : 'Your question stays here while the server prepares this file.'),
                  ),
                  if (upload['state'] != 'ready')
                    TextButton(
                      onPressed: () {
                        Navigator.pop(context);
                        unawaited(w.uploadFile(upload));
                      },
                      child: Text(
                        upload['state'] == 'failed'
                            ? 'Retry'
                            : 'Check processing',
                      ),
                    ),
                ],
              ),
            ),
          ),
          onDeleted: () => w.removeUpload(upload['localId'] as String),
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemBuilder: (_, index) => chips[index],
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemCount: chips.length,
      ),
    );
  }

  Future<void> _answerCall(Map<String, dynamic> call) async {
    Object? arguments = call['arguments'];
    if (arguments is String) {
      try {
        arguments = jsonDecode(arguments);
      } on Object {
        return;
      }
    }
    if (arguments is! Map) return;
    final response = await answerServerQuestions(
      context,
      arguments['questions'],
      allowOther: arguments['allow_other'] != false,
    );
    if (response != null) {
      await w.run?.resolveCall(
        (call['call_id'] ?? call['id']) as String,
        'answer',
        answers: response['answers'],
      );
    }
  }

  Future<void> _openSourceFile(SourceReference source) async {
    if (source.fileId == null || w.locked) return;
    final content = w.serverResources.sourceText(source.fileId!);
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => AnimatedBuilder(
        animation: w.session,
        builder: (context, _) => DraggableScrollableSheet(
          expand: false,
          initialChildSize: .8,
          builder: (context, scroll) => w.locked
              ? const Center(child: Text('Sign in again to view this source.'))
              : FutureBuilder<String>(
                  future: content,
                  builder: (context, snapshot) => ListView(
                    controller: scroll,
                    padding: const EdgeInsets.all(20),
                    children: [
                      Text(
                        source.title,
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      if (snapshot.hasError)
                        const Text(
                          'This source could not be opened with the current account. It may have been removed or access may have changed.',
                        )
                      else if (!snapshot.hasData)
                        const Center(child: CircularProgressIndicator())
                      else ...[
                        SelectableText(
                          snapshot.data!.substring(
                            0,
                            snapshot.data!.length.clamp(0, 100000),
                          ),
                        ),
                        if (snapshot.data!.length > 100000)
                          const Text(
                            'This preview shows the first 100,000 characters. Open the server web app for the full document.',
                          ),
                      ],
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _showQueue() => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) => AnimatedBuilder(
      animation: w,
      builder: (context, _) => DraggableScrollableSheet(
        expand: false,
        builder: (context, scroll) => ListView(
          controller: scroll,
          children: [
            const ListTile(
              title: Text('Queued follow-ups'),
              subtitle: Text(
                'Prompts remain paused after a restart or an uncertain response.',
              ),
            ),
            for (final item in w.queue)
              ListTile(
                title: Text(item['text'] as String),
                subtitle: item['intentId'] == null
                    ? null
                    : const Text('Linked to a saved request'),
                onTap: item['intentId'] != null
                    ? null
                    : () async {
                        final text = await _textDialog(
                          'Edit queued prompt',
                          item['text'] as String,
                        );
                        if (text != null) {
                          await w.editQueued(item['id'] as String, text);
                        }
                      },
                trailing: IconButton(
                  tooltip: 'Remove queued prompt',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => w.removeQueued(item['id'] as String),
                ),
              ),
            if (w.error != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(w.error!)),
          ],
        ),
      ),
    ),
  );

  Future<void> _export(bool portable) async {
    final id = w.conversation?.id;
    if (id == null || w.locked) return;
    final export = WebUiExport(w.session, w.accounts.store);
    try {
      final conversation = await export.completeBranch(id);
      if (!mounted || w.locked) return;
      if (portable) {
        await shareBackup(context, export.portableJson(conversation));
      } else {
        await shareConversationMarkdown(
          context,
          title: conversation.title,
          markdown: export.markdown(conversation),
        );
      }
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The complete server branch could not be loaded. Reconnect before exporting a portable copy.',
            ),
          ),
        );
      }
    }
  }

  Widget _history(bool persistent) => SafeArea(
    child: SizedBox(
      width: 300,
      child: Column(
        children: [
          ListTile(
            title: const Text('Shared chats'),
            subtitle: Text(w.session.identity.name),
            trailing: IconButton(
              tooltip: 'Account',
              icon: const Icon(Icons.logout),
              onPressed: _signOut,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(
                hintText: 'Search server chats',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (value) {
                _searchTimer?.cancel();
                _searchTimer = Timer(
                  const Duration(milliseconds: 250),
                  () => unawaited(w.search(value)),
                );
              },
            ),
          ),
          if (w.foldersAvailable)
            ListTile(
              leading: const Icon(Icons.folder_outlined),
              title: const Text('Folders'),
              onTap: w.locked
                  ? null
                  : () async {
                      final opened = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => WebUiFoldersScreen(workspace: w),
                        ),
                      );
                      if (opened == true && mounted && !persistent) {
                        Navigator.pop(context);
                      }
                    },
            ),
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  dense: true,
                  title: const Text('Archived'),
                  value: w.archived,
                  onChanged: (value) =>
                      w.search(_search.text, showArchived: value),
                ),
              ),
              IconButton(
                tooltip: 'Refresh chats',
                onPressed: w.locked ? null : w.refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          Expanded(
            child: ListView(
              children: [
                for (final chat in w.history)
                  ListTile(
                    selected: chat['id'] == w.conversation?.id,
                    title: Text(
                      chat['title'] as String? ??
                          (chat['chat'] as Map?)?['title'] as String? ??
                          'Chat',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    leading: chat['pinned'] == true
                        ? const Icon(Icons.push_pin_outlined, size: 16)
                        : null,
                    onTap: w.busy
                        ? null
                        : () async {
                            await w.open(chat['id'] as String);
                            if (mounted &&
                                !persistent &&
                                w.conversation?.id == chat['id']) {
                              Navigator.pop(context);
                            }
                          },
                    trailing: PopupMenuButton<String>(
                      tooltip: 'Chat actions',
                      enabled: w.online && !w.busy && !w.locked,
                      onSelected: (action) =>
                          _action(chat['id'] as String, action),
                      itemBuilder: (_) => [
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Rename'),
                        ),
                        if (w.foldersAvailable)
                          const PopupMenuItem(
                            value: 'folder',
                            child: Text('Move to folder'),
                          ),
                        PopupMenuItem(
                          value: 'pin',
                          child: Text(chat['pinned'] == true ? 'Unpin' : 'Pin'),
                        ),
                        PopupMenuItem(
                          value: 'archive',
                          child: Text(w.archived ? 'Unarchive' : 'Archive'),
                        ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Delete'),
                        ),
                      ],
                    ),
                  ),
                if (w.hasMore)
                  TextButton(
                    onPressed: () => w.refresh(more: true),
                    child: const Text('Load more chats'),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: FilledButton.icon(
              onPressed: w.busy
                  ? null
                  : () async {
                      await w.open(null);
                      if (mounted && !persistent) Navigator.pop(context);
                    },
              icon: const Icon(Icons.edit_outlined),
              label: const Text('New chat'),
            ),
          ),
          TextButton.icon(
            onPressed: () {
              if (!persistent) Navigator.pop(context);
              Navigator.pop(context);
            },
            icon: const Icon(Icons.arrow_back),
            label: const Text('Connections'),
          ),
        ],
      ),
    ),
  );

  Widget _runNotice() {
    final run = w.run;
    if (run == null) return const SizedBox.shrink();
    final pending = run.answer == null
        ? <Map<String, dynamic>>[]
        : webUiPendingCalls(run.answer!);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (run.problem != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(run.problem!)),
        if (run.state == WebUiRunState.uncertain)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => run.chatId == null
                  ? run.locateCreatedChat()
                  : run.reconcile(),
              icon: const Icon(Icons.refresh),
              label: Text(
                run.chatId == null ? 'Locate on server' : 'Check saved result',
              ),
            ),
          ),
        if (run.state == WebUiRunState.uncertain)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () async {
                final accepted = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Prepare a fresh attempt?'),
                    content: const Text(
                      'The original request may already have executed, including its tools. Another send could repeat that work. Its saved intent and partial output will remain. This prepares a new chat draft for you to review; it does not send.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const Text('Keep checking'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const Text('Prepare draft'),
                      ),
                    ],
                  ),
                );
                if (accepted == true) await w.prepareFreshAttempt();
              },
              child: const Text('Prepare fresh attempt'),
            ),
          ),
        for (final call in pending)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Approve ${call['name'] ?? 'server tool'}?',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: SelectableText('${call['arguments'] ?? ''}'),
                    ),
                  ),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton(
                        onPressed: () => run.resolveCall(
                          (call['call_id'] ?? call['id']) as String,
                          'reject',
                        ),
                        child: const Text('Deny'),
                      ),
                      if (call['name'] != 'ask_user')
                        FilledButton(
                          onPressed: () => run.resolveCall(
                            (call['call_id'] ?? call['id']) as String,
                            'approve',
                          ),
                          child: const Text('Allow'),
                        ),
                      if (call['name'] == 'ask_user')
                        FilledButton(
                          onPressed: () => _answerCall(call),
                          child: const Text('Answer'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: w,
    builder: (context, _) {
      if (w.locked) {
        return Scaffold(
          appBar: AppBar(title: const Text('Account locked')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Sign in again to unlock this account. Your local draft and pending request are retained.',
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Return to sign-in'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      final wide = MediaQuery.sizeOf(context).width >= 900;
      return Scaffold(
        appBar: AppBar(
          leading: wide
              ? const BackButton()
              : Builder(
                  builder: (context) => IconButton(
                    tooltip: 'Shared chats',
                    icon: const Icon(Icons.menu),
                    onPressed: () => Scaffold.of(context).openDrawer(),
                  ),
                ),
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                w.conversation?.title ?? 'New shared chat',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                '${w.session.client.root.host} · ${w.online ? 'Server history' : 'Cached · offline'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Chat mode',
              enabled: !w.locked && !w.running && !w.busy && w.online,
              icon: const Icon(Icons.chat_bubble_outline),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'temporary',
                  enabled:
                      (w.serverConfiguration['features']
                              as Map?)?['enable_websocket'] !=
                          false &&
                      (w.session.identity.role == 'admin' ||
                          (w.session.identity.permissions['chat']
                                  as Map?)?['temporary'] !=
                              false),
                  child: Text(
                    (w.serverConfiguration['features']
                                as Map?)?['enable_websocket'] ==
                            false
                        ? 'Temporary chat · Requires server live events'
                        : 'Temporary chat',
                  ),
                ),
              ],
              onSelected: (_) async {
                await w.flushDraft();
                if (!context.mounted) return;
                final saved = await Navigator.push<String>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => WebUiTemporaryScreen(workspace: w),
                  ),
                );
                if (saved != null) {
                  await w.refresh();
                  await w.open(saved);
                }
              },
            ),
            if (w.conversation != null)
              PopupMenuButton<String>(
                tooltip: 'Chat actions',
                onSelected: (action) async {
                  if (action == 'find') {
                    w.revealBranch();
                    _find.open();
                    return;
                  }
                  if (action == 'refresh') {
                    await w.refreshConversation();
                    return;
                  }
                  if (action == 'cached') {
                    final export = WebUiExport(w.session, w.accounts.store);
                    await shareConversationMarkdown(
                      context,
                      title: w.conversation!.title,
                      markdown: export.markdown(
                        w.conversation!,
                        incomplete: true,
                      ),
                    );
                  } else {
                    await _export(action == 'portable');
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'find',
                    child: Text('Find in chat'),
                  ),
                  const PopupMenuItem(
                    value: 'refresh',
                    child: Text('Refresh conversation'),
                  ),
                  PopupMenuItem(
                    value: 'readable',
                    enabled: w.online,
                    child: const Text('Export active branch'),
                  ),
                  PopupMenuItem(
                    value: 'portable',
                    enabled: w.online,
                    child: const Text('Export portable local copy'),
                  ),
                  if (!w.online)
                    const PopupMenuItem(
                      value: 'cached',
                      child: Text('Export incomplete cached text'),
                    ),
                ],
              ),

            IconButton(
              tooltip: 'New shared chat',
              onPressed: w.busy ? null : () => w.open(null),
              icon: const Icon(Icons.edit_outlined),
            ),
          ],
        ),
        drawer: wide ? null : Drawer(child: _history(false)),
        body: Row(
          children: [
            if (wide)
              Material(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: _history(true),
              ),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: Column(
                    children: [
                      AnimatedBuilder(
                        animation: _find,
                        builder: (context, _) => _find.isOpen
                            ? ChatFindBar(controller: _find)
                            : const SizedBox.shrink(),
                      ),
                      if (w.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Row(
                            children: [
                              Expanded(child: Text(w.error!)),
                              TextButton(
                                onPressed: () async {
                                  await w.refresh();
                                  await w.refreshConversation();
                                },
                                child: const Text('Retry'),
                              ),
                            ],
                          ),
                        ),
                      if (w.previewingVersion || w.anchorFingerprint != null)
                        _versionNotice(),
                      Expanded(
                        child: ChatTranscript(
                          messages: w.messages,
                          findController: _find,
                          findScope: w.scope,
                          hasOlder: w.hasOlder,
                          onLoadOlder: w.loadOlder,
                          messageFooter: _versionFooter,
                          canMutate: () => w.canRevise,
                          onRegenerate: (message) => w.revise(message.id),
                          onEditAndResend: (message, text) =>
                              w.revise(message.id, text: text),

                          onCopy: (text) =>
                              Clipboard.setData(ClipboardData(text: text)),
                          onAskSelection: _quote,
                          onOpenSourceFile: _openSourceFile,
                          emptyState: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(32),
                              child: Text(
                                'Chat with your server',
                                style: Theme.of(context)
                                    .textTheme
                                    .headlineSmall,
                              ),
                            ),
                          ),
                        ),
                      ),
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: MediaQuery.sizeOf(context).height * .28,
                        ),
                        child: SingleChildScrollView(child: _runNotice()),
                      ),
                      if (w.readOnlyConversation)
                        const Padding(
                          padding: EdgeInsets.all(12),
                          child: Text('Shared conversation · Read-only'),
                        ),
                      if (w.diverged)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'The server conversation changed. Your draft is preserved.',
                                ),
                              ),
                              TextButton(
                                onPressed: w.adoptContinuation,
                                child: const Text('Use current branch'),
                              ),
                            ],
                          ),
                        ),
                      if (w.queue.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextButton(
                                  onPressed: _showQueue,
                                  child: Text(
                                    '${w.queue.length} queued · ${w.queuePaused ? 'paused' : 'after this answer'}',
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: w.queuePaused
                                    ? w.resumeQueue
                                    : () {
                                        w.queuePaused = true;
                                        setState(() {});
                                      },
                                child: Text(w.queuePaused ? 'Resume' : 'Pause'),
                              ),
                            ],
                          ),
                        ),
                      SafeArea(
                        top: false,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: TextButton.icon(
                                      onPressed: w.models.isEmpty || w.busy
                                          ? null
                                          : _chooseModel,
                                      icon: const Icon(Icons.expand_more),
                                      label: Text(
                                        w.model.isEmpty
                                            ? 'No available models'
                                            : w.model,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                ),
                                PopupMenuButton<String>(
                                  tooltip: 'Chat resources',
                                  enabled: !w.busy && w.online,
                                  icon: const Icon(Icons.tune),
                                  onSelected: (value) => value == 'features'
                                      ? _features()
                                      : _pickResource(
                                          WebUiResourceKind.values.byName(
                                            value,
                                          ),
                                        ),
                                  itemBuilder: (_) => [
                                    for (final entry in const {
                                      'files': 'Server files',
                                      'knowledge': 'Knowledge',
                                      'prompts': 'Prompts',
                                      'skills': 'Skills',
                                      'tools': 'Tools',
                                      'features': 'Server features',
                                    }.entries)
                                      PopupMenuItem(
                                        value: entry.key,
                                        child: Text(entry.value),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            _selectedResources(),
                            if (RegExp(r'\$[^\s]*$').hasMatch(
                              _editor.text.substring(
                                0,
                                _editor.selection.isValid
                                    ? _editor.selection.start
                                    : _editor.text.length,
                              ),
                            ))
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: w.online
                                      ? () => _pickResource(
                                          WebUiResourceKind.skills,
                                          mention: true,
                                        )
                                      : null,
                                  icon: const Icon(Icons.alternate_email),
                                  label: const Text('Insert a skill'),
                                ),
                              ),
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight:
                                    MediaQuery.sizeOf(context).height * .3,
                              ),
                              child: ChatComposer(
                                controller: _editor,
                                focusNode: _focus,
                                draftText: w.draft,
                                draftScopeRevision: w.scopeRevision,
                                onDraftChanged: w.setDraft,
                                onSend: w.send,
                                onStop: () => w.run?.stop(),
                                isStreaming: w.running,
                                isQueueing: w.running,
                                editable: !w.busy,
                                canSubmit: w.canSend,
                                submitUnavailableReason: w.readOnlyConversation
                                    ? 'This shared conversation is read-only. Start your own chat to send messages.'
                                    : w.previewingVersion
                                    ? 'Choose Continue from this version before sending.'
                                    : !w.attachmentsReady
                                    ? 'Wait for attachments to finish preparing, retry, or remove them.'
                                    : !w.online
                                    ? 'Connect to send. You can keep drafting offline.'
                                    : 'Resolve the pending request or review the current branch before sending.',
                                imagesEnabled: w.visionAvailable,
                                onPickDocument: w.uploadsAvailable
                                    ? () => _pickFile()
                                    : null,
                                onPickImage: w.uploadsAvailable
                                    ? () => _pickFile(
                                        imageSource: ImageSource.gallery,
                                      )
                                    : null,
                                onTakePhoto: w.uploadsAvailable
                                    ? () => _pickFile(
                                        imageSource: ImageSource.camera,
                                      )
                                    : null,
                                onPasteImage: w.uploadsAvailable
                                    ? (bytes) =>
                                          w.addFile('Pasted image.png', bytes)
                                    : null,
                                hasAttachments:
                                    (w.resources['files'] as List? ?? [])
                                        .isNotEmpty,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}
