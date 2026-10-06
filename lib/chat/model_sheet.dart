import 'dart:async';

import 'package:flutter/material.dart';

import '../settings/settings_sheet.dart';
import '../ui/design.dart';
import 'chat_actions.dart';
import 'chat_controller.dart';
import 'model_management_page.dart';

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

  final chatProfileId = controller.conversationProfile.id;
  // Cached rows show immediately; the list refreshes separately and only the
  // selected model's details load. Nothing here takes a global lock.
  unawaited(controller.loadModelCapabilities(profileId: chatProfileId));
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: false,
    barrierColor: Design.ink.withValues(alpha: .70),
    builder: (context) => AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final profile = controller.conversationProfile;
        final ready = controller.conversationConnected;
        final selected = ready ? controller.selectedModel : null;
        final busy = !controller.canChangeContext;
        final existingChat = controller.conversation != null;
        final models = controller.modelsForProfile(profile.id);
        final refreshing =
            controller.modelListRefreshing(profile.id) ||
            controller.connectionStatusFor(profile.id) ==
                ConnectionStatus.checking;
        final listError = controller.modelListError(profile.id);
        final stored = controller.conversation?.selectedModel;
        final storedUnavailable =
            stored != null &&
            stored.isNotEmpty &&
            ready &&
            !refreshing &&
            listError == null &&
            !models.any((model) => model.name == stored);
        final error = generalChatError(controller);
        Future<void> choose(String model) async {
          final success = await controller.selectModel(model);
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
                  const SheetHeading(
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
                  if (error != null) _ErrorText(error),
                  if (refreshing) const _RefreshingModels(),
                  if (listError != null)
                    _ListError(
                      message: listError.message,
                      onRetry: () =>
                          controller.refreshModelList(profileId: profile.id),
                    ),
                  if (!ready && !refreshing)
                    _ModelRow(
                      title: 'Connect to ${profile.name}',
                      subtitle: 'Saved messages are available offline.',
                      onTap: busy
                          ? null
                          : () async {
                              if (await controller.connectConversation()) {
                                unawaited(
                                  controller.loadModelCapabilities(
                                    profileId: profile.id,
                                  ),
                                );
                              }
                            },
                    ),
                  if (storedUnavailable)
                    _ModelRow(
                      title: stored,
                      subtitle:
                          'Unavailable on ${profile.name}. Choose another model.',
                      onTap: null,
                    ),
                  if (ready &&
                      models.isEmpty &&
                      !refreshing &&
                      listError == null)
                    _NoModels(controller: controller, profileId: profile.id),
                  for (final model in models)
                    _ModelRow(
                      title: model.name,
                      subtitle: _modelSubtitle(
                        controller,
                        model.name,
                        profile.id,
                        profile.name,
                      ),
                      selected: model.name == selected,
                      detailsFailed:
                          controller.modelDetailsError(
                            model.name,
                            profileId: profile.id,
                          ) !=
                          null,
                      onRetryDetails: () => controller.loadModelDetails(
                        model.name,
                        profileId: profile.id,
                      ),
                      onTap: ready && !busy ? () => choose(model.name) : null,
                    ),
                  if (!controller.isTemporary)
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

/// Known capabilities fill in progressively; unknown ones stay unstated.
String _modelSubtitle(
  ChatController controller,
  String model,
  String profileId,
  String profileName,
) {
  if (controller.modelDetailsError(model, profileId: profileId) != null) {
    return '$profileName · Details unavailable';
  }
  if (controller.modelDetailsLoading(model, profileId: profileId)) {
    return '$profileName · Loading details…';
  }
  final details = controller.detailsForModel(model, profileId: profileId);
  return [
    profileName,
    if (details?.supportsThinking ?? false) 'Thinking',
    if (details?.supportsTools ?? false) 'Tools',
    if (details?.supportsVision ?? false) 'Images',
  ].join(' · ');
}

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.message);
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Text(
      message,
      style: TextStyle(color: Theme.of(context).colorScheme.error),
    ),
  );
}

class _RefreshingModels extends StatelessWidget {
  const _RefreshingModels();

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: <Widget>[
          const SizedBox.square(
            dimension: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: Design.space2),
          Expanded(
            child: Text(
              'Refreshing models…',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// A list refresh failure keeps cached rows and offers Retry in place.
class _ListError extends StatelessWidget {
  const _ListError({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Row(
    children: <Widget>[
      Expanded(
        child: Text(
          message,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      TextButton(
        style: TextButton.styleFrom(
          minimumSize: const Size(Design.target, Design.target),
        ),
        onPressed: onRetry,
        child: const Text('Retry'),
      ),
    ],
  );
}

/// A reachable server without models is a usable state, not an error.
class _NoModels extends StatelessWidget {
  const _NoModels({required this.controller, required this.profileId});
  final ChatController controller;
  final String profileId;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text('Server is reachable but has no available models'),
        Wrap(
          spacing: Design.space2,
          children: <Widget>[
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(Design.target, Design.target),
              ),
              onPressed: () =>
                  controller.refreshModelList(profileId: profileId),
              child: const Text('Refresh'),
            ),
            if (!controller.isTemporary &&
                controller.canManageModelsForProfile(profileId))
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size(Design.target, Design.target),
                ),
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ModelManagementPage(
                      controller: controller,
                      profileId: profileId,
                    ),
                  ),
                ),
                child: const Text('Manage models'),
              ),
          ],
        ),
      ],
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
      if (mounted) {
        unawaited(controller.refreshModelList(profileId: widget.profileId));
      }
    });
  }

  Future<void> _choose(String? model) async {
    if (_saving || !controller.canChangeContext) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final saved = await controller.setDefaultModelFor(widget.profileId, model);
    if (!mounted) return;
    if (saved) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _saving = false;
      _error =
          generalChatError(controller) ??
          'The default model could not be saved.';
    });
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final id = widget.profileId;
      final selected = controller.defaultModelFor(id);
      final models = controller.modelsForProfile(id);
      final refreshing = controller.modelListRefreshing(id);
      final listError = controller.modelListError(id);
      final busy = _saving || !controller.canChangeContext;
      final storedUnavailable =
          selected != null &&
          models.isNotEmpty &&
          !refreshing &&
          !models.any((model) => model.name == selected);
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
                if (refreshing) const _RefreshingModels(),
                if (_saving) const LinearProgressIndicator(),
                if (_error case final error?) _ErrorText(error),
                if (listError != null)
                  _ListError(
                    message: listError.message,
                    onRetry: () => controller.refreshModelList(profileId: id),
                  ),
                _ModelRow(
                  title: 'Last used',
                  subtitle: 'Use the latest model chosen on $_profileName',
                  selected: selected == null,
                  onTap: busy ? null : () => _choose(null),
                ),
                if (storedUnavailable)
                  _ModelRow(
                    title: selected,
                    subtitle:
                        'Unavailable on $_profileName. Choose another model.',
                    onTap: null,
                  ),
                for (final model in models)
                  _ModelRow(
                    title: model.name,
                    subtitle: _profileName,
                    selected: selected == model.name,
                    onTap: busy ? null : () => _choose(model.name),
                  ),
                if (!refreshing && listError == null && models.isEmpty)
                  _NoModels(controller: controller, profileId: id),
              ],
            ),
          ),
        ),
      );
    },
  );
}

class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.selected = false,
    this.trailing,
    this.detailsFailed = false,
    this.onRetryDetails,
  });
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final bool selected;
  final Widget? trailing;

  /// This model's details failed to load; offer a local retry.
  final bool detailsFailed;
  final VoidCallback? onRetryDetails;
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
      selected: selected,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (detailsFailed && onRetryDetails != null)
            TextButton(
              style: TextButton.styleFrom(
                minimumSize: const Size(Design.target, Design.target),
              ),
              onPressed: onRetryDetails,
              child: Text('Retry', semanticsLabel: 'Retry details for $title'),
            ),
          if (selected)
            const Icon(
              Icons.check,
              color: Design.accent,
              size: 23,
              semanticLabel: 'Selected',
            )
          else
            ?trailing,
        ],
      ),
      onTap: onTap,
    ),
  );
}
