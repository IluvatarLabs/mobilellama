import 'dart:async';

import 'package:flutter/material.dart';

import '../settings/settings_sheet.dart';
import '../ui/design.dart';
import 'chat_controller.dart';

Future<void> showModelSheet(
  BuildContext context,
  ChatController controller, {
  bool forDefaults = false,
  String? profileId,
}) async {
  if (forDefaults) {
    final id = profileId ?? controller.activeProfileId;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      barrierColor: Design.ink.withValues(alpha: .70),
      builder: (context) =>
          _DefaultModelPicker(controller: controller, profileId: id),
    );
    return;
  }

  unawaited(controller.loadModelCapabilities());
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    barrierColor: Design.ink.withValues(alpha: .70),
    builder: (context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final ready = controller.conversationConnected;
        final selected = controller.selectedModel;
        final busy = !controller.canChangeContext;
        final profile = controller.conversationProfile;
        final existingChat = controller.conversation != null;
        Future<void> choose(String? model) async {
          final success = await controller.selectModel(model!);
          if (success && context.mounted) Navigator.pop(context);
        }

        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .8,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 26),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHandle(),
                  SheetHeading(
                    title: 'Model',
                    closeLabel: 'Close model picker',
                  ),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      existingChat
                          ? 'This chat uses ${profile.name}. Its history stays with this server.'
                          : 'This new chat will use ${profile.name}.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  if (controller.errorMessage != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        controller.errorMessage!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  if (controller.modelLoading || controller.profileMutationBusy)
                    const LinearProgressIndicator(),
                  if (!ready)
                    _ModelRow(
                      title: 'Connect to ${profile.name}',
                      subtitle: 'Saved messages are available offline.',
                      onTap: busy
                          ? null
                          : () async {
                              await controller.connectConversation();
                              unawaited(controller.loadModelCapabilities());
                            },
                    ),
                  if (ready && controller.models.isEmpty)
                    _ModelRow(
                      title: 'No models returned',
                      subtitle: 'Tap to refresh',
                      onTap: busy ? null : controller.refreshModels,
                    ),
                  if (ready)
                    for (final model in controller.models)
                      _ModelRow(
                        title: model.name,
                        subtitle: [
                          profile.name,
                          if (controller
                                  .detailsForModel(model.name)
                                  ?.supportsThinking ??
                              false)
                            'Thinking',
                          if (controller
                                  .detailsForModel(model.name)
                                  ?.supportsTools ??
                              false)
                            'Tools',
                          if (controller
                                  .detailsForModel(model.name)
                                  ?.supportsVision ??
                              false)
                            'Images',
                        ].join(' · '),
                        selected: model.name == selected,
                        onTap: busy ? null : () => choose(model.name),
                      ),
                  _ModelRow(
                    title: existingChat
                        ? 'New chat on another server'
                        : 'Choose server for new chat',
                    subtitle: existingChat
                        ? 'This chat and its history stay on ${profile.name}.'
                        : '${controller.profiles.length} saved servers',
                    trailing: const DesignIcon('chevron'),
                    onTap: busy
                        ? null
                        : () async {
                            await Navigator.push<void>(
                              context,
                              MaterialPageRoute(
                                builder: (_) => SettingsSheet(
                                  controller: controller,
                                  section: SettingsSection.servers,
                                ),
                              ),
                            );
                            unawaited(controller.loadModelCapabilities());
                          },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _DefaultModelPicker extends StatefulWidget {
  const _DefaultModelPicker({
    required this.controller,
    required this.profileId,
  });

  final ChatController controller;
  final String profileId;

  @override
  State<_DefaultModelPicker> createState() => _DefaultModelPickerState();
}

class _DefaultModelPickerState extends State<_DefaultModelPicker> {
  List<ChatModelOption> _models = const [];
  bool _loading = true;
  bool _saving = false;
  String? _error;

  ChatController get controller => widget.controller;

  String get _profileName =>
      controller.profiles
          .where((profile) => profile.id == widget.profileId)
          .map((profile) => profile.name)
          .firstOrNull ??
      'this server';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final models = await controller.loadModelsForProfile(widget.profileId);
      if (mounted) setState(() => _models = models);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _models = const [];
          _error = controller.errorMessage ?? error.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _choose(String? model) async {
    if (_loading || _saving || !controller.canChangeContext) return;
    setState(() => _saving = true);
    final saved = await controller.setDefaultModelFor(widget.profileId, model);
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = false;
      _error =
          controller.errorMessage ?? 'The default model could not be saved.';
    });
  }

  @override
  Widget build(BuildContext context) {
    final selected = controller.defaultModelFor(widget.profileId);
    final busy = _loading || _saving || !controller.canChangeContext;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .8,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 26),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const SheetHandle(),
              SheetHeading(
                title: 'Default model for $_profileName',
                closeLabel: 'Close default model picker',
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'Applies to future chats on $_profileName. Existing chats keep their model.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (_loading || _saving) const LinearProgressIndicator(),
              if (_error case final error?)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              _ModelRow(
                title: 'Last used',
                subtitle: 'Use the latest model chosen on $_profileName',
                selected: selected == null,
                onTap: busy ? null : () => _choose(null),
              ),
              for (final model in _models)
                _ModelRow(
                  title: model.name,
                  subtitle: _profileName,
                  selected: selected == model.name,
                  onTap: busy ? null : () => _choose(model.name),
                ),
              if (!_loading && _models.isEmpty)
                _ModelRow(
                  title: 'No models returned',
                  subtitle: 'Tap to try $_profileName again',
                  onTap: _saving ? null : _load,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.selected = false,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool selected;
  final Widget? trailing;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: Border(top: BorderSide(color: Design.line(context, .12))),
    ),
    child: ListTile(
      contentPadding: EdgeInsets.zero,
      minTileHeight: 62,
      minVerticalPadding: 8,
      title: Text(
        title,
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(
          fontSize: 14,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: selected
          ? const Icon(
              Icons.check,
              color: Design.accent,
              size: 23,
              semanticLabel: 'Selected',
            )
          : trailing,
      onTap: onTap,
    ),
  );
}
