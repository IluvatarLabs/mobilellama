import 'dart:convert';

import 'package:flutter/material.dart';

import '../domain/generation_options.dart';
import '../domain/prompt_preset.dart';
import '../ui/design.dart';
import 'chat_controller.dart';

class PromptPresetsPage extends StatefulWidget {
  const PromptPresetsPage({
    super.key,
    required this.controller,
    this.allowApply = false,
    this.startWithCreate = false,
    this.seedSystemPrompt,
    this.seedOptions,
  });

  final ChatController controller;
  final bool allowApply;
  final bool startWithCreate;
  final String? seedSystemPrompt;
  final GenerationOptions? seedOptions;

  @override
  State<PromptPresetsPage> createState() => _PromptPresetsPageState();
}

class _PromptPresetsPageState extends State<PromptPresetsPage> {
  bool _busy = false;
  bool _openedInitialEditor = false;

  ChatController get controller => widget.controller;
  bool get _enabled => !_busy && controller.canChangeContext;

  @override
  void initState() {
    super.initState();
    if (widget.startWithCreate) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _openedInitialEditor) return;
        _openedInitialEditor = true;
        _editPreset();
      });
    }
  }

  Future<void> _editPreset([PromptPreset? preset]) async {
    if (!_enabled) {
      _showUnavailable();
      return;
    }
    final draft = await showModalBottomSheet<_PresetDraft>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      requestFocus: true,
      showDragHandle: false,
      builder: (context) => _PresetEditorSheet(
        preset: preset,
        seedSystemPrompt: widget.seedSystemPrompt ?? controller.systemPrompt,
        seedOptions: widget.seedOptions ?? controller.generationOptions,
      ),
    );
    if (draft == null || !mounted) return;
    if (!_enabled) {
      _showUnavailable();
      return;
    }
    setState(() => _busy = true);
    final saved = await controller.savePromptPreset(
      id: preset?.id,
      name: draft.name,
      systemPrompt: draft.systemPrompt,
      generationOptions: draft.options,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (!saved) {
      _showControllerError('The preset could not be saved.');
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(preset == null ? 'Preset created.' : 'Preset updated.'),
        ),
      );
    }
  }

  Future<void> _deletePreset(PromptPreset preset) async {
    if (!_enabled) {
      _showUnavailable();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete preset?'),
        content: Text(
          'Delete “${preset.name}”? This does not change any chat settings.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
              minimumSize: const Size(44, 44),
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!_enabled ||
        !controller.promptPresets.any((item) => item.id == preset.id)) {
      _showUnavailable();
      return;
    }
    setState(() => _busy = true);
    final deleted = await controller.deletePromptPreset(preset.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!deleted) _showControllerError('The preset could not be deleted.');
  }

  Future<void> _applyPreset(PromptPreset preset) async {
    final conversation = controller.conversation;
    if (!_enabled || conversation == null) {
      _showUnavailable();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Apply preset to this chat?'),
        content: Text(
          '“${preset.name}” will replace this chat’s instructions and generation settings. Messages stay unchanged.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    if (!_enabled || controller.conversation?.id != conversation.id) {
      _showUnavailable();
      return;
    }
    setState(() => _busy = true);
    final applied = await controller.applyPromptPreset(preset.id);
    if (!mounted) return;
    setState(() => _busy = false);
    if (!applied) {
      _showControllerError('The preset could not be applied.');
      return;
    }
    Navigator.pop(context, true);
  }

  void _showUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Wait for the current action to finish.')),
    );
  }

  void _showControllerError(String fallback) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(controller.errorMessage ?? fallback)),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Prompt presets')),
    body: SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) {
          final presets = controller.promptPresets;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: <Widget>[
              Text(
                'Save instructions and generation settings for reuse. Applying changes only the current chat.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _enabled ? _editPreset : null,
                icon: const Icon(Icons.add),
                label: const Text('Create preset'),
              ),
              const SizedBox(height: 20),
              if (presets.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: Text('No prompt presets yet.')),
                )
              else
                for (final preset in presets) ...<Widget>[
                  _PresetCard(
                    preset: preset,
                    enabled: _enabled,
                    allowApply:
                        widget.allowApply && controller.conversation != null,
                    onEdit: () => _editPreset(preset),
                    onDelete: () => _deletePreset(preset),
                    onApply: () => _applyPreset(preset),
                  ),
                  const SizedBox(height: 10),
                ],
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Center(child: CircularProgressIndicator()),
                ),
            ],
          );
        },
      ),
    ),
  );
}

class _PresetCard extends StatelessWidget {
  const _PresetCard({
    required this.preset,
    required this.enabled,
    required this.allowApply,
    required this.onEdit,
    required this.onDelete,
    required this.onApply,
  });

  final PromptPreset preset;
  final bool enabled;
  final bool allowApply;
  final VoidCallback onEdit;
  final VoidCallback onDelete;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final options = preset.generationOptions;
    final summary = <String>[
      if (options.temperature case final value?) 'Temperature $value',
      if (options.contextSize case final value?) 'Context $value',
      if (options.maxTokens case final value?) 'Max tokens $value',
    ].join(' · ');
    return Material(
      color: Design.group(context),
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    preset.name,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Edit ${preset.name}',
                  onPressed: enabled ? onEdit : null,
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                  icon: const Icon(Icons.edit_outlined, size: 19),
                ),
                IconButton(
                  tooltip: 'Delete ${preset.name}',
                  onPressed: enabled ? onDelete : null,
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                  icon: const Icon(Icons.delete_outline, size: 19),
                ),
              ],
            ),
            if (preset.systemPrompt.trim().isNotEmpty)
              Text(
                preset.systemPrompt.trim(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            if (summary.isNotEmpty) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                summary,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            if (allowApply) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(44, 44),
                  ),
                  onPressed: enabled ? onApply : null,
                  child: const Text('Apply to this chat'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _PresetDraft {
  const _PresetDraft({
    required this.name,
    required this.systemPrompt,
    required this.options,
  });

  final String name;
  final String systemPrompt;
  final GenerationOptions options;
}

class _PresetEditorSheet extends StatefulWidget {
  const _PresetEditorSheet({
    required this.preset,
    required this.seedSystemPrompt,
    required this.seedOptions,
  });

  final PromptPreset? preset;
  final String seedSystemPrompt;
  final GenerationOptions seedOptions;

  @override
  State<_PresetEditorSheet> createState() => _PresetEditorSheetState();
}

class _PresetEditorSheetState extends State<_PresetEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _instructions;
  late final TextEditingController _temperature;
  late final TextEditingController _contextSize;
  late final TextEditingController _maxTokens;

  GenerationOptions get _baseOptions =>
      widget.preset?.generationOptions ?? widget.seedOptions;

  @override
  void initState() {
    super.initState();
    final options = _baseOptions;
    _name = TextEditingController(text: widget.preset?.name ?? '');
    _instructions = TextEditingController(
      text: widget.preset?.systemPrompt ?? widget.seedSystemPrompt,
    );
    _temperature = TextEditingController(
      text: options.temperature?.toString() ?? '',
    );
    _contextSize = TextEditingController(
      text: options.contextSize?.toString() ?? '',
    );
    _maxTokens = TextEditingController(
      text: options.maxTokens?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _instructions.dispose();
    _temperature.dispose();
    _contextSize.dispose();
    _maxTokens.dispose();
    super.dispose();
  }

  void _save() {
    if (_formKey.currentState?.validate() != true) return;
    final options = _baseOptions.copyWith(
      temperature: _readDouble(_temperature),
      contextSize: _readInt(_contextSize),
      maxTokens: _readInt(_maxTokens),
    );
    Navigator.pop(
      context,
      _PresetDraft(
        name: _name.text.trim(),
        systemPrompt: _instructions.text.trim(),
        options: options,
      ),
    );
  }

  String? _validateName(String? value) {
    final length = value?.trim().length ?? 0;
    if (length < 1 || length > 80) {
      return 'Give the preset a name of 1–80 characters.';
    }
    return null;
  }

  String? _validateInstructions(String? value) {
    if (utf8.encode(value ?? '').length > 64 * 1024) {
      return 'Instructions can be at most 64 KB.';
    }
    return null;
  }

  String? _validateNumber(
    String? value, {
    required String label,
    required num minimum,
    required bool integer,
  }) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return null;
    final parsed = integer ? int.tryParse(text) : double.tryParse(text);
    if (parsed == null || !parsed.isFinite) return 'Enter a valid $label.';
    if (parsed < minimum) return '$label must be at least $minimum.';
    return null;
  }

  static int? _readInt(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : int.parse(value);
  }

  static double? _readDouble(TextEditingController controller) {
    final value = controller.text.trim();
    return value.isEmpty ? null : double.parse(value);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .9,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SheetHandle(),
              SheetHeading(
                title: widget.preset == null ? 'Create preset' : 'Edit preset',
                closeLabel: 'Close preset editor',
              ),
              const SizedBox(height: 8),
              Flexible(
                child: Form(
                  key: _formKey,
                  child: SingleChildScrollView(
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        TextFormField(
                          key: const ValueKey<String>('preset-name-field'),
                          controller: _name,
                          autofocus: true,
                          maxLength: 80,
                          validator: _validateName,
                          decoration: const InputDecoration(
                            labelText: 'Name',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _instructions,
                          minLines: 3,
                          maxLines: 7,
                          validator: _validateInstructions,
                          textCapitalization: TextCapitalization.sentences,
                          decoration: const InputDecoration(
                            labelText: 'Instructions',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _temperature,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          validator: (value) => _validateNumber(
                            value,
                            label: 'temperature',
                            minimum: 0,
                            integer: false,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Temperature',
                            hintText: 'Model default',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _contextSize,
                          keyboardType: TextInputType.number,
                          validator: (value) => _validateNumber(
                            value,
                            label: 'context size',
                            minimum: 1,
                            integer: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Context size',
                            hintText: 'Model default',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _maxTokens,
                          keyboardType: TextInputType.number,
                          validator: (value) => _validateNumber(
                            value,
                            label: 'max tokens',
                            minimum: -2,
                            integer: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Max tokens',
                            hintText: 'Model default',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 4),
                  FilledButton(
                    onPressed: _save,
                    child: const Text('Save preset'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
