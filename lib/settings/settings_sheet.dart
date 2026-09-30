import 'package:flutter/material.dart';

import '../chat/chat_controller.dart';
import '../chat/model_sheet.dart';
import '../chat/model_management_page.dart';
import '../chat/presets_page.dart';
import '../data/settings_store.dart';
import '../domain/generation_options.dart';
import '../ui/design.dart';
import 'connection_form.dart';

export 'connection_form.dart' show showConnectionForm, confirmServerDestination;

const _settingsControlShape = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(10)),
);

enum SettingsSection { servers, defaults, conversation, webAgent, appearance }

class SettingsSheet extends StatefulWidget {
  const SettingsSheet({
    super.key,
    required this.controller,
    this.section = SettingsSection.servers,
  });

  final ChatController controller;
  final SettingsSection section;

  @override
  State<SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<SettingsSheet> {
  final _conversationFormKey = GlobalKey<FormState>();
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _webKeyController = TextEditingController();
  final TextEditingController _temperatureController = TextEditingController();
  final TextEditingController _seedController = TextEditingController();
  final TextEditingController _maxTokensController = TextEditingController();
  final TextEditingController _contextSizeController = TextEditingController();
  final TextEditingController _repeatLastNController = TextEditingController();
  final TextEditingController _repeatPenaltyController =
      TextEditingController();
  final TextEditingController _tailFreeSamplingController =
      TextEditingController();
  final TextEditingController _topKController = TextEditingController();
  final TextEditingController _topPController = TextEditingController();
  final TextEditingController _minPController = TextEditingController();
  final TextEditingController _mirostatController = TextEditingController();
  final TextEditingController _mirostatEtaController = TextEditingController();
  final TextEditingController _mirostatTauController = TextEditingController();

  String? _selectedProfileId;
  String? _loadedConversationId;
  bool _saving = false;
  bool _advancedExpanded = false;

  @override
  void initState() {
    super.initState();
    _selectedProfileId = widget.controller.conversationProfile.id;
    _loadConversation();
    widget.controller.addListener(_handleControllerChanged);
  }

  ServerProfile? _selectedProfile(ChatController controller) {
    final configured = controller.profiles.where((p) => p.configured);
    return configured.where((p) => p.id == _selectedProfileId).firstOrNull ??
        configured.firstOrNull;
  }

  bool get _serverBusy =>
      _saving ||
      widget.controller.profileMutationBusy ||
      widget.controller.isConnecting ||
      widget.controller.isStreaming ||
      widget.controller.isSubmitting ||
      widget.controller.modelLoading;
  bool get _isDefaults => widget.section == SettingsSection.defaults;
  GenerationOptions get _editedOptions => _isDefaults
      ? widget.controller.chatDefaults.generationOptions
      : widget.controller.generationOptions;
  bool get _usesOllama =>
      _isDefaults ||
      widget.controller.conversationProfile.protocol == ServerProtocol.ollama;
  bool get _conversationBusy =>
      !_isDefaults &&
          (_saving ||
              widget.controller.profileMutationBusy ||
              widget.controller.isConnecting ||
              widget.controller.isStreaming ||
              widget.controller.isSubmitting ||
              widget.controller.modelLoading) ||
      _saving;

  void _handleControllerChanged() {
    final conversationId = widget.controller.conversation?.id;
    if (!_isDefaults && !_saving && conversationId != _loadedConversationId) {
      _loadConversation();
    }
  }

  void _loadConversation() {
    final conversation = widget.controller.conversation;
    _loadedConversationId = conversation?.id;
    _advancedExpanded = false;
    _promptController.text = _isDefaults
        ? widget.controller.chatDefaults.systemPrompt
        : widget.controller.systemPrompt;
    final options = _editedOptions;
    _setNumber(_temperatureController, options.temperature);
    _setNumber(_seedController, options.seed);
    _setNumber(_maxTokensController, options.maxTokens);
    _setNumber(_contextSizeController, options.contextSize);
    _setNumber(_repeatLastNController, options.repeatLastN);
    _setNumber(_repeatPenaltyController, options.repeatPenalty);
    _setNumber(_tailFreeSamplingController, options.tailFreeSampling);
    _setNumber(_topKController, options.topK);
    _setNumber(_topPController, options.topP);
    _setNumber(_minPController, options.minP);
    _setNumber(_mirostatController, options.mirostat);
    _setNumber(_mirostatEtaController, options.mirostatEta);
    _setNumber(_mirostatTauController, options.mirostatTau);
  }

  static void _setNumber(TextEditingController controller, num? value) {
    controller.text = value?.toString() ?? '';
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _promptController.dispose();
    _webKeyController.dispose();
    _temperatureController.dispose();
    _seedController.dispose();
    _maxTokensController.dispose();
    _contextSizeController.dispose();
    _repeatLastNController.dispose();
    _repeatPenaltyController.dispose();
    _tailFreeSamplingController.dispose();
    _topKController.dispose();
    _topPController.dispose();
    _minPController.dispose();
    _mirostatController.dispose();
    _mirostatEtaController.dispose();
    _mirostatTauController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(switch (widget.section) {
          SettingsSection.servers => 'Connections',
          SettingsSection.defaults => 'Chat defaults',
          SettingsSection.conversation => 'Chat settings',
          SettingsSection.webAgent => 'Web search',
          SettingsSection.appearance => 'Appearance',
        }),
      ),
      body: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: widget.controller,
          builder: (context, _) {
            final controller = widget.controller;
            final theme = Theme.of(context);
            final colors = theme.colorScheme;
            final selectedProfile = _selectedProfile(controller);
            return ListView(
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: EdgeInsets.fromLTRB(
                16,
                16,
                16,
                16 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              children: <Widget>[
                switch (widget.section) {
                  SettingsSection.servers => _buildServerProfiles(
                    controller,
                    theme,
                    colors,
                  ),
                  SettingsSection.defaults || SettingsSection.conversation =>
                    _buildConversationSettings(controller, theme, colors),
                  SettingsSection.webAgent => _buildWebAgentSettings(
                    controller,
                    colors,
                  ),
                  SettingsSection.appearance => _buildAppearanceSettings(
                    controller,
                  ),
                },
                if (widget.section == SettingsSection.servers &&
                    selectedProfile != null) ...[
                  const SizedBox(height: 24),
                  _buildServerDefaults(controller, selectedProfile),
                ],
                if (widget.section == SettingsSection.servers &&
                    selectedProfile?.protocol ==
                        ServerProtocol.openAiCompatible) ...[
                  const SizedBox(height: 24),
                  _SettingsSection(
                    title: 'Capabilities for ${selectedProfile!.name}',
                    child: _SettingsSurface(
                      child: Column(
                        children: [
                          const Text(
                            'Enable capabilities supported by your server when its model list does not report them.',
                          ),
                          if (controller.hasServerApiKeyForProfile(
                            selectedProfile.id,
                          ))
                            TextButton(
                              onPressed: _serverBusy
                                  ? null
                                  : () async {
                                      try {
                                        await controller.removeServerApiKey(
                                          profileId: selectedProfile.id,
                                        );
                                      } on Object catch (error) {
                                        _showMessage(
                                          'Key could not be removed: $error',
                                        );
                                      }
                                    },
                              child: const Text('Remove stored API key'),
                            ),
                          for (final entry in const {
                            'vision': 'Image input',
                            'tools': 'Tool calling',
                          }.entries)
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              title: Text(entry.value),
                              value: controller
                                  .compatibleCapabilitiesForProfile(
                                    selectedProfile.id,
                                  )
                                  .contains(entry.key),
                              onChanged: _serverBusy
                                  ? null
                                  : (value) async {
                                      try {
                                        await controller
                                            .setCompatibleCapability(
                                              entry.key,
                                              value,
                                              profileId: selectedProfile.id,
                                            );
                                      } on Object catch (error) {
                                        _showMessage(
                                          'Capability could not be saved: $error',
                                        );
                                      }
                                    },
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
                if (widget.section == SettingsSection.servers &&
                    selectedProfile?.protocol == ServerProtocol.ollama) ...[
                  const SizedBox(height: 24),
                  _buildModelManagement(controller, selectedProfile!),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildWebAgentSettings(ChatController controller, ColorScheme colors) {
    return _SettingsSection(
      title: 'Web search',
      child: _SettingsSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Web search lets a model that supports tools look things up online. It uses Ollama cloud services (ollama.com) and needs an Ollama cloud API key. The key and this preference apply across chats.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _SettingsField(
              label: 'Ollama cloud API key',
              child: TextField(
                controller: _webKeyController,
                enabled: !_serverBusy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                onChanged: (_) => setState(() {}),
                decoration: _tonalFieldDecoration(
                  context,
                  hintText: controller.hasWebApiKey ? '••••••••' : null,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: <Widget>[
                if (controller.hasWebApiKey)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                    ),
                    onPressed: _serverBusy ? null : _removeKey,
                    child: const Text('Remove key'),
                  ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed:
                      _serverBusy || _webKeyController.text.trim().isEmpty
                      ? null
                      : _saveKey,
                  child: const Text('Save key'),
                ),
              ],
            ),
            Divider(color: colors.outlineVariant),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: controller.webAgentEnabled,
              onChanged: _serverBusy ? null : _setWebAgent,
              title: const Text('Use web search'),
              subtitle: !controller.supportsTools
                  ? Text(
                      controller.selectedModel == null
                          ? 'Unavailable in this chat until you choose a model that supports tools.'
                          : 'Unavailable in this chat: ${controller.selectedModel} does not support tools.',
                    )
                  : null,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildServerDefaults(
    ChatController controller,
    ServerProfile profile,
  ) {
    final defaultModel = controller.defaultModelFor(profile.id);
    return _SettingsSection(
      title: 'New chats on ${profile.name}',
      child: _SettingsSurface(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Existing chats keep their own server and model.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              minTileHeight: 56,
              title: const Text('Default model'),
              subtitle: Text(defaultModel ?? 'Last used on this server'),
              trailing: const Icon(Icons.chevron_right),
              onTap: _serverBusy
                  ? null
                  : () => showModelSheet(
                      context,
                      controller,
                      forDefaults: true,
                      profileId: profile.id,
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelManagement(
    ChatController controller,
    ServerProfile profile,
  ) => _SettingsSurface(
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 56,
      title: Text('Models on ${profile.name}'),
      subtitle: const Text('Download and remove models on this server.'),
      trailing: const Icon(Icons.chevron_right),
      onTap: _serverBusy
          ? null
          : () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) => ModelManagementPage(
                  controller: controller,
                  profileId: profile.id,
                ),
              ),
            ),
    ),
  );

  Widget _buildAppearanceSettings(ChatController controller) {
    return _SettingsSection(
      title: 'Appearance',
      child: _SettingsSurface(
        child: Align(
          alignment: Alignment.centerLeft,
          child: SegmentedButton<ThemePreference>(
            segments: const <ButtonSegment<ThemePreference>>[
              ButtonSegment(
                value: ThemePreference.system,
                label: Text('System'),
              ),
              ButtonSegment(value: ThemePreference.light, label: Text('Light')),
              ButtonSegment(value: ThemePreference.dark, label: Text('Dark')),
            ],
            selected: <ThemePreference>{controller.themePreference},
            showSelectedIcon: false,
            expandedInsets: EdgeInsets.zero,
            style: SegmentedButton.styleFrom(shape: _settingsControlShape),
            onSelectionChanged: _saving
                ? null
                : (selection) async {
                    try {
                      await controller.setThemePreference(selection.single);
                    } on Object catch (error) {
                      _showMessage('The theme could not be saved: $error');
                    }
                  },
          ),
        ),
      ),
    );
  }

  Widget _buildServerProfiles(
    ChatController controller,
    ThemeData theme,
    ColorScheme colors,
  ) {
    if (!controller.isConfigured) {
      return _SettingsSection(
        title: 'Connections',
        child: _SettingsSurface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Text(
                'No server is set up yet. Models run on your own Ollama or '
                'OpenAI-compatible server.',
              ),
              const SizedBox(height: Design.space3),
              FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _serverBusy ? null : _openConnectionForm,
                child: const Text('Connect a server'),
              ),
            ],
          ),
        ),
      );
    }
    final profiles = controller.profiles.where((p) => p.configured).toList();
    final selected = _selectedProfile(controller)!;
    final status = controller.connectionStatusFor(selected.id);
    final failure = controller.connectionFailureFor(selected.id);
    final usage = [
      if (controller.conversation?.serverProfileId == selected.id)
        'This chat uses this server'
      else if (selected.id == controller.activeProfileId)
        'Used for new chats',
    ];
    return _SettingsSection(
      title: 'Connections',
      trailing: TextButton.icon(
        onPressed: _serverBusy ? null : _openConnectionForm,
        icon: const Icon(Icons.add, size: 20),
        label: const Text('New connection'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Material(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: <Widget>[
                for (var i = 0; i < profiles.length; i++) ...<Widget>[
                  if (i > 0) Divider(height: 1, color: colors.outlineVariant),
                  ListTile(
                    minTileHeight: 56,
                    selected: profiles[i].id == selected.id,
                    title: Text(
                      profiles[i].name,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      profiles[i].baseUrl,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      controller.connectionStatusFor(profiles[i].id).label,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    onTap: () =>
                        setState(() => _selectedProfileId = profiles[i].id),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: Design.space3),
          _SettingsSurface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  [status.label, ...usage].join(' · '),
                  style: theme.textTheme.bodyMedium,
                ),
                if (failure != null) ...<Widget>[
                  const SizedBox(height: Design.space1),
                  Text(
                    failure.message,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.error,
                    ),
                  ),
                ],
                const SizedBox(height: Design.space3),
                Wrap(
                  spacing: Design.space2,
                  runSpacing: Design.space2,
                  children: <Widget>[
                    OutlinedButton(
                      onPressed: _serverBusy
                          ? null
                          : () => _openConnectionForm(profile: selected),
                      child: const Text('Edit connection'),
                    ),
                    if (status != ConnectionStatus.ready)
                      OutlinedButton(
                        onPressed:
                            _serverBusy || status == ConnectionStatus.checking
                            ? null
                            : () => _connectProfile(selected),
                        child: const Text('Connect'),
                      ),
                    FilledButton.tonal(
                      onPressed: _serverBusy
                          ? null
                          : () => _startChatOnProfile(selected),
                      child: Text('New chat on ${selected.name}'),
                    ),
                    TextButton.icon(
                      onPressed: _serverBusy || profiles.length == 1
                          ? null
                          : () => _confirmDeleteProfile(selected),
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('Delete'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConversationSettings(
    ChatController controller,
    ThemeData theme,
    ColorScheme colors,
  ) {
    final enabled = !_conversationBusy;
    final ollama = _usesOllama;
    return _SettingsSection(
      title: _isDefaults ? 'For new chats' : 'For this chat',
      child: _SettingsSurface(
        child: Form(
          key: _conversationFormKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_isDefaults) ...[
                Text(
                  'Applies to new chats on every server. Existing chats keep their own settings. Leave a value blank to use the model’s default.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 16),
              ],
              if (!_isDefaults) ...<Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: enabled ? _openPresets : null,
                        icon: const Icon(Icons.bookmarks_outlined),
                        label: const Text('Presets'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(48),
                        ),
                        onPressed: enabled
                            ? () => _openPresets(create: true)
                            : null,
                        icon: const Icon(Icons.bookmark_add_outlined),
                        label: const Text('Save as preset'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              _SettingsField(
                label: 'Instructions',
                child: TextField(
                  controller: _promptController,
                  enabled: enabled,
                  minLines: 2,
                  maxLines: 5,
                  decoration: _tonalFieldDecoration(
                    context,
                    hintText: _isDefaults
                        ? 'How would you like the assistant to respond?'
                        : 'Instructions for this chat',
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _NullableNumberField(
                controller: _temperatureController,
                label: 'Temperature',
                minimum: 0,
                enabled: enabled,
              ),
              const SizedBox(height: 12),
              _NullableNumberField(
                controller: _seedController,
                label: 'Seed',
                integer: true,
                minimum: 0,
                enabled: enabled,
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: enabled
                      ? () => setState(
                          () => _advancedExpanded = !_advancedExpanded,
                        )
                      : null,
                  icon: Icon(
                    _advancedExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                  ),
                  label: Text(
                    _advancedExpanded ? 'Hide advanced' : 'Show advanced',
                  ),
                ),
              ),
              Visibility(
                visible: _advancedExpanded,
                maintainState: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _NullableNumberField(
                      controller: _maxTokensController,
                      label: 'Max Tokens',
                      integer: true,
                      minimum: ollama && !_isDefaults ? -2 : 1,
                      enabled: enabled,
                    ),
                    const SizedBox(height: 12),
                    _NullableNumberField(
                      controller: _topPController,
                      label: 'Top P',
                      minimum: 0,
                      maximum: 1,
                      enabled: enabled,
                    ),
                    const SizedBox(height: 12),
                    _NullableNumberField(
                      controller: _contextSizeController,
                      label: 'Context Size',
                      integer: true,
                      minimum: 0,
                      minimumExclusive: true,
                      enabled: enabled,
                    ),
                    if (ollama) ...<Widget>[
                      const SizedBox(height: 12),
                      if (_isDefaults) ...<Widget>[
                        Text(
                          'Ollama-specific options',
                          style: Theme.of(context).textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 12),
                      ],
                      _NullableNumberField(
                        controller: _repeatLastNController,
                        label: 'Repeat Last N',
                        integer: true,
                        minimum: -1,
                        enabled: enabled,
                      ),
                      const SizedBox(height: 12),
                      _NullableNumberField(
                        controller: _repeatPenaltyController,
                        label: 'Repeat Penalty',
                        minimum: 0,
                        enabled: enabled,
                      ),
                      const SizedBox(height: 12),
                      _NullableNumberField(
                        controller: _tailFreeSamplingController,
                        label: 'Tail Free Sampling',
                        minimum: 0,
                        enabled: enabled,
                      ),
                      const SizedBox(height: 12),
                      _NullableNumberField(
                        controller: _topKController,
                        label: 'Top K',
                        integer: true,
                        minimum: 0,
                        enabled: enabled,
                      ),
                      const SizedBox(height: 12),
                      _NullableNumberField(
                        controller: _minPController,
                        label: 'Min P',
                        minimum: 0,
                        maximum: 1,
                        enabled: enabled,
                      ),
                      const SizedBox(height: 12),
                      _NullableNumberField(
                        controller: _mirostatController,
                        label: 'Mirostat',
                        integer: true,
                        minimum: 0,
                        maximum: 2,
                        enabled: enabled,
                      ),
                      const SizedBox(height: 12),
                      _NullableNumberField(
                        controller: _mirostatEtaController,
                        label: 'Mirostat Eta',
                        minimum: 0,
                        enabled: enabled,
                      ),
                      const SizedBox(height: 12),
                      _NullableNumberField(
                        controller: _mirostatTauController,
                        label: 'Mirostat Tau',
                        minimum: 0,
                        enabled: enabled,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(48, 48),
                  ),
                  onPressed: enabled ? _saveConversationSettings : null,
                  child: Text(
                    _isDefaults ? 'Save defaults' : 'Save chat settings',
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openConnectionForm({ServerProfile? profile}) async {
    await showConnectionForm(context, widget.controller, profile: profile);
    if (!mounted) return;
    final configured = widget.controller.profiles.where((p) => p.configured);
    setState(() {
      // Show the connection just created or set up.
      if (profile == null && configured.isNotEmpty) {
        _selectedProfileId = configured.last.id;
      }
    });
  }

  /// First Connect of a saved profile shows the destination disclosure.
  Future<void> _connectProfile(ServerProfile profile) async {
    if (!await confirmServerDestination(context, widget.controller, profile)) {
      return;
    }
    try {
      await widget.controller.loadModelsForProfile(profile.id);
    } on Object {
      // The status and failure for this profile are shown in place.
    }
  }

  Future<void> _startChatOnProfile(ServerProfile profile) async {
    if (!await confirmServerDestination(context, widget.controller, profile) ||
        !mounted) {
      return;
    }
    setState(() => _saving = true);
    try {
      final started = await widget.controller.newConversationOnServer(
        profile.id,
      );
      if (!started) {
        _showMessage(
          widget.controller.errorMessage ??
              'A new chat could not be started on this server.',
        );
        return;
      }
      if (mounted) {
        Navigator.of(
          context,
        ).popUntil((route) => route.isFirst && !route.willHandlePopInternally);
      }
    } on Object catch (error) {
      _showMessage('A new chat could not be started: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDeleteProfile(ServerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete connection?'),
        content: Text('Delete “${profile.name}”?'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _saving = true);
    try {
      final deleted = await widget.controller.deleteServerProfile(profile.id);
      if (!deleted) {
        _showMessage(
          widget.controller.errorMessage ??
              'The connection could not be deleted right now.',
        );
        return;
      }
      if (mounted) {
        setState(() => _selectedProfileId = widget.controller.activeProfileId);
      }
      _showMessage('Connection deleted.');
    } on Object catch (error) {
      _showMessage('The connection could not be deleted: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveConversationSettings() async {
    if (_conversationFormKey.currentState?.validate() != true) {
      if (!_advancedExpanded) {
        setState(() => _advancedExpanded = true);
      }
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _saving = true);
    try {
      final options = _readConversationOptions();
      final save = _isDefaults
          ? widget.controller.updateChatDefaults
          : widget.controller.updateConversationSettings;
      final saved = await save(
        systemPrompt: _promptController.text,
        generationOptions: options,
      );
      if (!saved) {
        _showMessage(
          widget.controller.errorMessage ??
              'Settings could not be saved right now.',
        );
        return;
      }
      _loadConversation();
      _showMessage(
        _isDefaults ? 'Defaults saved for new chats.' : 'Chat settings saved.',
      );
    } on Object catch (error) {
      _showMessage('Settings could not be saved: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  GenerationOptions _readConversationOptions() {
    final current = _editedOptions;
    final ollama = _usesOllama;
    return GenerationOptions(
      temperature: _readDouble(_temperatureController),
      seed: _readInt(_seedController),
      maxTokens: _readInt(_maxTokensController),
      contextSize: _readInt(_contextSizeController),
      repeatLastN: ollama
          ? _readInt(_repeatLastNController)
          : current.repeatLastN,
      repeatPenalty: ollama
          ? _readDouble(_repeatPenaltyController)
          : current.repeatPenalty,
      tailFreeSampling: ollama
          ? _readDouble(_tailFreeSamplingController)
          : current.tailFreeSampling,
      topK: ollama ? _readInt(_topKController) : current.topK,
      topP: _readDouble(_topPController),
      minP: ollama ? _readDouble(_minPController) : current.minP,
      mirostat: ollama ? _readInt(_mirostatController) : current.mirostat,
      mirostatEta: ollama
          ? _readDouble(_mirostatEtaController)
          : current.mirostatEta,
      mirostatTau: ollama
          ? _readDouble(_mirostatTauController)
          : current.mirostatTau,
    );
  }

  Future<void> _openPresets({bool create = false}) async {
    GenerationOptions? seedOptions;
    String? seedPrompt;
    if (create) {
      if (_conversationFormKey.currentState?.validate() != true) {
        if (!_advancedExpanded) setState(() => _advancedExpanded = true);
        return;
      }
      seedOptions = _readConversationOptions();
      seedPrompt = _promptController.text;
    }
    final applied = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => PromptPresetsPage(
          controller: widget.controller,
          allowApply: !_isDefaults,
          startWithCreate: create,
          seedSystemPrompt: seedPrompt,
          seedOptions: seedOptions,
        ),
      ),
    );
    if (!mounted || applied != true) return;
    setState(_loadConversation);
  }

  static int? _readInt(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : int.parse(value);
  }

  static double? _readDouble(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : double.parse(value);
  }

  Future<void> _saveKey() async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveWebApiKey(_webKeyController.text);
      _webKeyController.clear();
    } on Object catch (error) {
      _showMessage('The Ollama cloud API key could not be saved: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _removeKey() async {
    setState(() => _saving = true);
    try {
      await widget.controller.saveWebApiKey('');
    } on Object catch (error) {
      _showMessage('The Ollama cloud API key could not be removed: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _setWebAgent(bool enabled) async {
    try {
      if (!enabled) {
        await widget.controller.setWebAgentEnabled(false);
        return;
      }

      if (!widget.controller.webDisclosureAcknowledged) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Web search uses Ollama cloud services'),
            content: const Text(
              'Search terms, page URLs, and fetched page content leave your local network and are sent to Ollama. Regular chat goes to your configured server.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Continue'),
              ),
            ],
          ),
        );
        if (accepted != true) return;
        await widget.controller.acknowledgeWebDisclosure();
      }

      if (!widget.controller.hasWebApiKey) {
        if (_webKeyController.text.trim().isEmpty) {
          _showMessage('Save an Ollama cloud API key first.');
          return;
        }
        await widget.controller.saveWebApiKey(_webKeyController.text);
        _webKeyController.clear();
      }
      final enabledSuccessfully = await widget.controller.setWebAgentEnabled(
        true,
      );
      if (!enabledSuccessfully) {
        _showMessage('Web search is not available for this chat’s model.');
      }
    } on Object catch (error) {
      _showMessage('Web search settings could not be saved: $error');
    }
  }

  void _showMessage(String value) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(value)));
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.child,
    this.trailing,
  });

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(
              child: Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _SettingsSurface extends StatelessWidget {
  const _SettingsSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(shape: _settingsControlShape),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(shape: _settingsControlShape),
        ),
      ),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    );
  }
}

InputDecoration _tonalFieldDecoration(
  BuildContext context, {
  String? hintText,
}) {
  final colors = Theme.of(context).colorScheme;
  const radius = BorderRadius.all(Radius.circular(10));
  const quietBorder = OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide.none,
  );
  return InputDecoration(
    hintText: hintText,
    filled: true,
    fillColor: colors.surfaceContainerHighest,
    isDense: true,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    border: quietBorder,
    enabledBorder: quietBorder,
    disabledBorder: quietBorder,
    focusedBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.primary),
    ),
    errorBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.error),
    ),
    focusedErrorBorder: OutlineInputBorder(
      borderRadius: radius,
      borderSide: BorderSide(color: colors.error),
    ),
  );
}

class _SettingsField extends StatelessWidget {
  const _SettingsField({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Semantics(label: label, child: child),
      ],
    );
  }
}

class _NullableNumberField extends StatelessWidget {
  const _NullableNumberField({
    required this.controller,
    required this.label,
    required this.enabled,
    this.integer = false,
    this.minimum,
    this.minimumExclusive = false,
    this.maximum,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;
  final bool integer;
  final num? minimum;
  final bool minimumExclusive;
  final num? maximum;

  @override
  Widget build(BuildContext context) {
    return _SettingsField(
      label: label,
      child: TextFormField(
        controller: controller,
        enabled: enabled,
        keyboardType: TextInputType.numberWithOptions(
          decimal: !integer,
          signed: true,
        ),
        textInputAction: TextInputAction.next,
        autovalidateMode: AutovalidateMode.onUserInteraction,
        decoration: _tonalFieldDecoration(context, hintText: 'Model default'),
        validator: (raw) {
          final value = raw?.trim() ?? '';
          if (value.isEmpty) return null;
          late final num parsed;
          if (integer) {
            final integerValue = int.tryParse(value);
            if (integerValue == null) return 'Enter an integer';
            parsed = integerValue;
          } else {
            final decimalValue = double.tryParse(value);
            if (decimalValue == null || !decimalValue.isFinite) {
              return 'Enter a number';
            }
            parsed = decimalValue;
          }
          if (minimum != null &&
              (minimumExclusive ? parsed <= minimum! : parsed < minimum!)) {
            return minimumExclusive
                ? 'Must be greater than $minimum'
                : 'Minimum $minimum';
          }
          if (maximum != null && parsed > maximum!) {
            return 'Maximum $maximum';
          }
          return null;
        },
      ),
    );
  }
}
