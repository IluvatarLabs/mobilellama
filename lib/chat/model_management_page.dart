import 'dart:async';

import 'package:flutter/material.dart';

import '../data/settings_store.dart';
import '../ollama/ollama_client.dart';
import '../ui/design.dart';
import 'chat_controller.dart';

class ModelManagementPage extends StatefulWidget {
  const ModelManagementPage({
    super.key,
    required this.controller,
    required this.profileId,
  });

  final ChatController controller;
  final String profileId;

  @override
  State<ModelManagementPage> createState() => _ModelManagementPageState();
}

class _ModelManagementPageState extends State<ModelManagementPage> {
  final _modelName = TextEditingController();

  ChatController get controller => widget.controller;

  ServerProfile? get profile {
    for (final candidate in controller.profiles) {
      if (candidate.id == widget.profileId) return candidate;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _modelName.addListener(_modelNameChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_refresh());
    });
  }

  @override
  void dispose() {
    _modelName
      ..removeListener(_modelNameChanged)
      ..dispose();
    super.dispose();
  }

  void _modelNameChanged() => setState(() {});

  Future<void> _refresh() async {
    if (!controller.canManageModelsForProfile(widget.profileId)) return;
    try {
      await controller.loadModelsForProfile(widget.profileId);
    } on Object {
      // The controller exposes the actionable scoped error in the page.
    }
  }

  Future<void> _download() async {
    final model = _modelName.text.trim();
    if (model.isEmpty ||
        !controller.canManageModelsForProfile(widget.profileId) ||
        controller.modelManagementBusyForProfile(widget.profileId)) {
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    final success = await controller.pullModel(
      model,
      profileId: widget.profileId,
    );
    if (success && mounted) _modelName.clear();
  }

  Future<void> _delete(String model) async {
    if (!controller.canManageModelsForProfile(widget.profileId) ||
        controller.modelManagementBusyForProfile(widget.profileId)) {
      _showUnavailable();
      return;
    }
    final selectedProfile = profile;
    if (selectedProfile == null) {
      _showUnavailable();
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $model?'),
        content: Text(
          'Delete $model from ${selectedProfile.name}? The model files will be removed '
          'from that server. Existing conversations keep their messages, but '
          'this model cannot be selected until it is installed again.',
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

    if (profile?.id != selectedProfile.id ||
        !controller.canManageModelsForProfile(widget.profileId) ||
        controller.modelManagementBusyForProfile(widget.profileId)) {
      _showUnavailable();
      return;
    }
    await controller.deleteModel(model, profileId: widget.profileId);
  }

  void _showUnavailable() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Wait for the current action to finish.')),
    );
  }

  Future<void> _showDetails(String model) async {
    final details = controller.detailsForModel(
      model,
      profileId: widget.profileId,
    );
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      barrierColor: Design.ink.withValues(alpha: .70),
      builder: (sheetContext) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * .8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SheetHandle(),
                SheetHeading(
                  title: model,
                  closeLabel: 'Close model information',
                ),
                if (details == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 18),
                    child: Text('The server did not return model information.'),
                  )
                else
                  ..._detailRows(
                    details,
                  ).map((row) => _ModelDetailRow(label: row.$1, value: row.$2)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<(String, String)> _detailRows(OllamaShowResponse details) {
    final metadata = details.details;
    final capabilities = details.capabilities.toList()..sort();
    return <(String, String)>[
      if (metadata.family.isNotEmpty) ('Family', metadata.family),
      if (metadata.families.isNotEmpty)
        ('Families', metadata.families.join(', ')),
      if (metadata.parameterSize.isNotEmpty)
        ('Parameters', metadata.parameterSize),
      if (metadata.quantizationLevel.isNotEmpty)
        ('Quantization', metadata.quantizationLevel),
      if (metadata.format.isNotEmpty) ('Format', metadata.format),
      if (capabilities.isNotEmpty) ('Capabilities', capabilities.join(', ')),
    ];
  }

  String _modelSubtitle(String model) {
    final details = controller.detailsForModel(
      model,
      profileId: widget.profileId,
    );
    if (details == null) return 'Model information';
    final metadata = details.details;
    final parts = <String>[
      if (metadata.parameterSize.isNotEmpty) metadata.parameterSize,
      if (metadata.quantizationLevel.isNotEmpty) metadata.quantizationLevel,
      if (metadata.family.isNotEmpty) metadata.family,
    ];
    if (parts.isEmpty && details.capabilities.isNotEmpty) {
      final capabilities = details.capabilities.toList()..sort();
      parts.add(capabilities.join(', '));
    }
    return parts.isEmpty ? 'Model information' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final selectedProfile = profile;
    final isOllama = selectedProfile?.protocol == ServerProtocol.ollama;
    return Scaffold(
      backgroundColor: Design.panel(context),
      appBar: AppBar(
        title: const Text('Models'),
        backgroundColor: Design.panel(context),
      ),
      body: SafeArea(
        top: false,
        child: AnimatedBuilder(
          animation: controller,
          builder: (context, _) => ListView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              16,
              14,
              16,
              24 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            children: <Widget>[
              if (selectedProfile == null)
                const _UnavailableServer()
              else
                _ServerContext(
                  name: selectedProfile.name,
                  baseUrl: selectedProfile.baseUrl,
                  isOllama: isOllama,
                ),
              if (isOllama) ...<Widget>[
                const SizedBox(height: 24),
                _DownloadSection(
                  controller: controller,
                  profileId: widget.profileId,
                  modelName: _modelName,
                  onDownload: _download,
                ),
                const SizedBox(height: 24),
                _InstalledModels(
                  controller: controller,
                  profileId: widget.profileId,
                  subtitleFor: _modelSubtitle,
                  onDetails: _showDetails,
                  onDelete: _delete,
                  onRefresh: _refresh,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UnavailableServer extends StatelessWidget {
  const _UnavailableServer();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.symmetric(vertical: 24),
    child: Text('This saved server is no longer available.'),
  );
}

class _ServerContext extends StatelessWidget {
  const _ServerContext({
    required this.name,
    required this.baseUrl,
    required this.isOllama,
  });

  final String name;
  final String baseUrl;
  final bool isOllama;

  @override
  Widget build(BuildContext context) => Material(
    color: Design.group(context),
    borderRadius: BorderRadius.circular(16),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            name,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            baseUrl,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            isOllama
                ? 'Models are stored on $name, not this phone.'
                : 'Model management is available only for Ollama servers. '
                      '$name is a compatible server.',
          ),
        ],
      ),
    ),
  );
}

class _DownloadSection extends StatelessWidget {
  const _DownloadSection({
    required this.controller,
    required this.profileId,
    required this.modelName,
    required this.onDownload,
  });

  final ChatController controller;
  final String profileId;
  final TextEditingController modelName;
  final Future<void> Function() onDownload;

  @override
  Widget build(BuildContext context) {
    final busy = controller.modelManagementBusyForProfile(profileId);
    final enabled = controller.canManageModelsForProfile(profileId) && !busy;
    final canDownload = enabled && modelName.text.trim().isNotEmpty;
    return _Section(
      title: 'Download a model',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          LayoutBuilder(
            builder: (context, constraints) {
              final stack =
                  constraints.maxWidth < 430 ||
                  MediaQuery.textScalerOf(context).scale(17) > 22;
              final field = TextField(
                controller: modelName,
                enabled: enabled,
                autocorrect: false,
                textCapitalization: TextCapitalization.none,
                textInputAction: TextInputAction.done,
                onSubmitted: canDownload ? (_) => onDownload() : null,
                decoration: const InputDecoration(
                  labelText: 'Model name',
                  hintText: 'model:tag',
                  border: OutlineInputBorder(),
                ),
              );
              final button = FilledButton(
                onPressed: canDownload ? onDownload : null,
                style: FilledButton.styleFrom(minimumSize: const Size(110, 48)),
                child: const Text('Download'),
              );
              if (stack) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[field, const SizedBox(height: 10), button],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: field),
                  const SizedBox(width: 10),
                  button,
                ],
              );
            },
          ),
          if (!enabled && !busy)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                'Wait for the current chat action to finish.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          if (busy ||
              controller.modelManagementStatusForProfile(profileId) !=
                  null) ...<Widget>[
            const SizedBox(height: 16),
            Semantics(
              liveRegion: true,
              child: Text(
                controller.modelManagementStatusForProfile(profileId) ??
                    'Working…',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
          if (busy) ...<Widget>[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: controller.modelDownloadProgressForProfile(profileId),
            ),
            if (controller.modelPullActiveForProfile(profileId)) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      controller.cancelModelPull(profileId: profileId),
                  style: TextButton.styleFrom(minimumSize: const Size(72, 44)),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ],
          if (controller.modelManagementErrorForProfile(profileId)
              case final error?) ...<Widget>[
            const SizedBox(height: 12),
            Semantics(
              liveRegion: true,
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _InstalledModels extends StatelessWidget {
  const _InstalledModels({
    required this.controller,
    required this.profileId,
    required this.subtitleFor,
    required this.onDetails,
    required this.onDelete,
    required this.onRefresh,
  });

  final ChatController controller;
  final String profileId;
  final String Function(String) subtitleFor;
  final Future<void> Function(String) onDetails;
  final Future<void> Function(String) onDelete;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final models = controller.modelsForProfile(profileId);
    final canDelete =
        controller.canManageModelsForProfile(profileId) &&
        !controller.modelManagementBusyForProfile(profileId);
    return _Section(
      title: 'Installed models',
      trailing: TextButton(
        onPressed: canDelete ? onRefresh : null,
        style: TextButton.styleFrom(minimumSize: const Size(72, 44)),
        child: const Text('Refresh'),
      ),
      child: models.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('No installed models returned.'),
            )
          : Column(
              children: <Widget>[
                for (var index = 0; index < models.length; index++) ...<Widget>[
                  if (index > 0)
                    Divider(height: 1, color: Design.line(context, .10)),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    minTileHeight: 62,
                    title: Text(
                      models[index].name,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(subtitleFor(models[index].name)),
                    onTap: () => onDetails(models[index].name),
                    trailing: IconButton(
                      tooltip: 'Delete ${models[index].name}',
                      onPressed: canDelete
                          ? () => onDelete(models[index].name)
                          : null,
                      constraints: const BoxConstraints(
                        minWidth: 44,
                        minHeight: 44,
                      ),
                      icon: const Icon(Icons.delete_outline),
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});

  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      Row(
        children: <Widget>[
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
      const SizedBox(height: 8),
      Material(
        color: Design.group(context),
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(padding: const EdgeInsets.all(14), child: child),
      ),
    ],
  );
}

class _ModelDetailRow extends StatelessWidget {
  const _ModelDetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 112,
          child: Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}
