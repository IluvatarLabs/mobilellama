import 'package:flutter/material.dart';

import '../chat/chat_actions.dart';
import '../chat/chat_controller.dart';
import '../chat/history.dart';
import '../chat/presets_page.dart';
import '../chat/share_actions.dart';
import '../data/settings_store.dart';
import '../data/chat_sync.dart';
import '../ui/design.dart';
import 'help_about.dart';
import 'settings_sheet.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.controller});
  final ChatController controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  ChatController get controller => widget.controller;
  String? _dataAction;

  Future<void> _editor(BuildContext context, SettingsSection section) =>
      Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              SettingsSheet(controller: controller, section: section),
        ),
      );

  Future<void> _push(BuildContext context, Widget page) =>
      Navigator.push<void>(context, MaterialPageRoute(builder: (_) => page));

  Future<void> _backUpChats(BuildContext context) async {
    if (_dataAction != null) return;
    if (!controller.canChangeContext) {
      showChatError(context, controller);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Back up chats?'),
        content: const Text(
          'This backup contains private chat content, images, documents, and chat settings. '
          'API keys and unsent drafts are excluded. Nothing is sent unless you '
          'choose a destination in the native share sheet.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    if (!controller.canChangeContext) {
      showChatError(context, controller);
      return;
    }
    setState(() => _dataAction = 'Preparing backup…');
    try {
      final json = await controller.exportBackup();
      if (!context.mounted) return;
      await shareBackup(context, json);
    } on Object {
      if (mounted) {
        _showDataError('The chat backup could not be prepared.');
      }
    } finally {
      if (mounted) setState(() => _dataAction = null);
    }
  }

  Future<void> _importChats(BuildContext context) async {
    if (_dataAction != null) return;
    if (!controller.canChangeContext) {
      showChatError(context, controller);
      return;
    }
    setState(() => _dataAction = 'Choosing backup…');
    try {
      final json = await pickBackupJson();
      if (json == null || !context.mounted) return;
      if (!controller.canChangeContext) {
        showChatError(context, controller);
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import chats?'),
          content: const Text(
            'Chats from this backup will be added. Your existing chats will stay.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      if (!controller.canChangeContext) {
        showChatError(context, controller);
        return;
      }
      setState(() => _dataAction = 'Importing chats…');
      final count = await controller.importBackup(json);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count == 1 ? 'Imported 1 chat.' : 'Imported $count chats.',
          ),
        ),
      );
    } on BackupFileTooLargeException {
      if (mounted) {
        _showDataError('Choose a backup smaller than 128 MiB.');
      }
    } on FormatException {
      if (mounted) {
        _showDataError('This is not a valid MobileLlama backup.');
      }
    } on Object {
      if (mounted) {
        _showDataError('The chat backup could not be imported.');
      }
    } finally {
      if (mounted) setState(() => _dataAction = null);
    }
  }

  void _showDataError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Design.panel(context),
    appBar: AppBar(
      automaticallyImplyLeading: false,
      backgroundColor: Design.panel(context),
      toolbarHeight: 64,
      leadingWidth: 58,
      leading: Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Center(
          child: RoundAction(
            label: 'Close settings',
            icon: 'close',
            onPressed: () => Navigator.pop(context),
          ),
        ),
      ),
    ),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(
            Design.gutter,
            Design.space3,
            Design.gutter,
            Design.space5,
          ),
          children: [
            const Text(
              'Settings',
              style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
            ),
            _Group(
              title: 'Connections',
              children: [
                if (controller.isConfigured)
                  _Row(
                    label: 'Servers',
                    value:
                        '${controller.profiles.where((p) => p.configured).length}',
                    detail:
                        'Addresses, keys, default models, and capabilities.',
                    onTap: () => _editor(context, SettingsSection.servers),
                  )
                else
                  _Row(
                    label: 'Connect a server',
                    detail: 'Models run on your own Ollama or OpenAI-compatible server.',
                    onTap: () => showConnectionForm(context, controller),
                  ),
              ],
            ),
            _Group(
              title: 'Chat',
              children: [
                _Row(
                  label: 'Chat defaults',
                  detail:
                      'Instructions and generation settings for future chats.',
                  onTap: () => _editor(context, SettingsSection.defaults),
                ),
                _Row(
                  label: 'Prompt presets',
                  value: '${controller.promptPresets.length}',
                  onTap: () => Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PromptPresetsPage(
                        controller: controller,
                        allowApply: controller.conversation != null,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            _Group(
              title: 'Appearance',
              children: [
                _Row(
                  label: 'Theme',
                  value: switch (controller.themePreference) {
                    ThemePreference.system => 'System',
                    ThemePreference.light => 'Light',
                    ThemePreference.dark => 'Dark',
                  },
                  onTap: () => _editor(context, SettingsSection.appearance),
                ),
              ],
            ),
            _Group(
              title: 'Web search',
              children: [
                _Row(
                  label: 'Web search',
                  value: controller.webAgentEnabled ? 'On' : 'Off',
                  detail: 'Optional. Uses Ollama cloud services with models that support tools.',
                  onTap: () => _editor(context, SettingsSection.webAgent),
                ),
              ],
            ),
            _Group(
              title: 'Data & sync',
              children: [
                _Row(
                  label: 'Archived chats',
                  value: '${controller.archivedHistory.length}',
                  onTap: () async {
                    final opened = await Navigator.push<bool>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ChatHistoryPage(
                          controller: controller,
                          archived: true,
                        ),
                      ),
                    );
                    if (opened == true && context.mounted) {
                      Navigator.pop(context, true);
                    }
                  },
                ),
                _Row(
                  label: 'Back up chats',
                  detail: 'Private chat content, images, and documents; API keys are excluded.',
                  onTap: _dataAction == null
                      ? () => _backUpChats(context)
                      : null,
                ),
                _Row(
                  label: 'Import chats',
                  detail: 'Adds chats from a MobileLlama backup.',
                  onTap: _dataAction == null
                      ? () => _importChats(context)
                      : null,
                ),
                if (ChatSyncBridge.configured)
                  _Row(
                    label: 'iCloud sync',
                    value: _syncSummary(controller.chatSync),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => _ChatSyncPage(controller: controller),
                      ),
                    ),
                  ),
                if (_dataAction case final action?)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    child: Semantics(
                      liveRegion: true,
                      child: Row(
                        children: <Widget>[
                          const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Expanded(child: Text(action)),
                        ],
                      ),
                    ),
                  ),
                _Row(
                  label: 'Delete all chats',
                  destructive: true,
                  onTap: () async {
                    if (!controller.canChangeContext) {
                      showChatError(context, controller);
                      return;
                    }
                    if (!await confirmDelete(
                      context,
                      title: 'Delete all chats?',
                      message: 'All conversations, unsent drafts, and stored attachments will be permanently deleted. Server profiles and settings will stay.',
                    )) {
                      return;
                    }
                    final success = await controller.deleteAllConversations();
                    if (!context.mounted) return;
                    if (!success || controller.errorMessage != null) {
                      showChatError(context, controller);
                    } else {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('All chats deleted.')),
                      );
                    }
                  },
                ),
              ],
            ),
            _Group(
              title: 'Help & About',
              children: [
                _Row(
                  label: 'Connection help',
                  onTap: () => _push(context, const ConnectionHelpPage()),
                ),
                _Row(
                  label: 'Privacy',
                  onTap: () => _push(context, const PrivacyInfoPage()),
                ),
                if (kPrivacyPolicyUrl.isNotEmpty)
                  _Row(
                    label: 'Privacy policy',
                    onTap: () => openExternalUrl(context, kPrivacyPolicyUrl),
                  ),
                _Row(
                  label: 'Report a problem',
                  detail:
                      'Opens GitHub issues. Nothing is attached automatically.',
                  onTap: () => openExternalUrl(context, kIssuesUrl),
                ),
                _Row(
                  label: 'About MobileLlama',
                  onTap: () => _push(context, const AboutPage()),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

String _syncSummary(ChatSyncService? sync) {
  if (sync == null || !sync.state.supported) return 'Unavailable';
  if (!sync.state.enabled) return 'Off';
  if (sync.working) return 'Syncing…';
  if (sync.error != null || sync.state.error != null) return 'Needs attention';
  if (sync.state.pending > 0) return '${sync.state.pending} pending';
  return sync.state.lastSync == null ? 'Not synced yet' : 'On';
}

class _ChatSyncPage extends StatelessWidget {
  const _ChatSyncPage({required this.controller});

  final ChatController controller;

  Future<void> _setEnabled(BuildContext context, bool enabled) async {
    final sync = controller.chatSync;
    if (sync == null || !sync.state.supported) return;
    if (!controller.canChangeContext || sync.working) {
      _showError(context, 'Wait for the current action to finish.');
      return;
    }
    if (enabled) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Enable iCloud sync?'),
          content: const Text(
            'Sync chats and attachments to your private iCloud account. API keys and drafts stay on this device. Conflicting edits are kept as separate chats.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Enable'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    if (controller.chatSync != sync ||
        !controller.canChangeContext ||
        sync.working) {
      if (context.mounted) {
        _showError(context, 'Wait for the current action to finish.');
      }
      return;
    }
    final changed = await sync.setEnabled(enabled);
    if (!context.mounted) return;
    if (!changed) {
      _showError(
        context,
        sync.error ?? sync.state.error ?? 'iCloud sync could not be changed.',
      );
    }
  }

  Future<void> _syncNow(BuildContext context) async {
    final sync = controller.chatSync;
    if (sync == null ||
        !sync.state.supported ||
        !sync.state.enabled ||
        sync.working ||
        !controller.canChangeContext) {
      _showError(context, 'Wait for the current action to finish.');
      return;
    }
    await sync.synchronize(network: true);
    if (!context.mounted || controller.chatSync != sync) return;
    final error = sync.error ?? sync.state.error;
    if (error != null) _showError(context, error);
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _status(ChatSyncService sync, BuildContext context) {
    final state = sync.state;
    final error = sync.error ?? state.error;
    if (error != null) return error;
    if (sync.working) return 'Syncing chats and attachments…';
    if (!state.enabled) {
      return 'Off. Disabling sync keeps all local chat history.';
    }
    if (state.pending > 0) {
      final noun = state.pending == 1 ? 'change' : 'changes';
      return '${state.pending} $noun waiting to sync.';
    }
    final value = state.lastSync;
    if (value == null) return 'Not synced yet.';
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return 'Last sync: $value';
    final date = MaterialLocalizations.of(context).formatShortDate(parsed);
    final time = TimeOfDay.fromDateTime(parsed).format(context);
    return 'Last synced $date at $time.';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('iCloud sync')),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final sync = controller.chatSync;
          final supported = sync?.state.supported == true;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: <Widget>[
              if (!supported) ...<Widget>[
                Text(
                  'iCloud sync is unavailable. It requires iOS 17 or later and an available iCloud account.',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                if (sync?.error ?? sync?.state.error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ] else ...<Widget>[
                Material(
                  color: Design.group(context),
                  borderRadius: BorderRadius.circular(16),
                  clipBehavior: Clip.antiAlias,
                  child: SwitchListTile(
                    minTileHeight: 56,
                    title: const Text('Sync chats with iCloud'),
                    subtitle: const Text(
                      'Chats and attachments use your private iCloud account. API keys and drafts stay on this device.',
                    ),
                    value: sync!.state.enabled,
                    onChanged: sync.working || !controller.canChangeContext
                        ? null
                        : (value) => _setEnabled(context, value),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  _status(sync, context),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: (sync.error ?? sync.state.error) == null
                        ? Theme.of(context).colorScheme.onSurfaceVariant
                        : Theme.of(context).colorScheme.error,
                  ),
                ),
                if (sync.notice case final notice?) ...<Widget>[
                  const SizedBox(height: 8),
                  Text(notice, style: Theme.of(context).textTheme.bodyMedium),
                ],
                const SizedBox(height: 16),
                FilledButton.tonalIcon(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed:
                      sync.state.enabled &&
                          !sync.working &&
                          controller.canChangeContext
                      ? () => _syncNow(context)
                      : null,
                  icon: sync.working
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(sync.working ? 'Syncing…' : 'Sync now'),
                ),
              ],
            ],
          );
        },
      ),
    ),
  );
}

class _Group extends StatelessWidget {
  const _Group({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 24, 12, 9),
        child: Semantics(
          header: true,
          child: Text(
            title,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
      ),
      Material(
        color: Design.group(context),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, color: Design.line(context, .10)),
              children[i],
            ],
          ],
        ),
      ),
    ],
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.onTap,
    this.value,
    this.detail,
    this.destructive = false,
  });
  final String label;
  final String? value;
  final String? detail;
  final VoidCallback? onTap;
  final bool destructive;
  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(17) > 22;
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      minTileHeight: 58,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 17,
          color: destructive ? colors.error : null,
        ),
      ),
      subtitle: switch ((detail, large ? value : null)) {
        (final String detail, final String value) => Text('$detail\n$value'),
        (final String detail, _) => Text(detail),
        (_, final String value) => Text(value),
        _ => null,
      },
      trailing: large || value == null
          ? const DesignIcon('chevron', size: 20)
          : ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width * .34,
              ),
              child: Text(
                value!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 15, color: colors.onSurfaceVariant),
              ),
            ),
      onTap: onTap,
    );
  }
}
