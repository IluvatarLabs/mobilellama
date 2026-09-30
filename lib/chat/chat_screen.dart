import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:url_launcher/url_launcher.dart';

import '../data/settings_store.dart';
import '../domain/conversation.dart';
import '../domain/document_attachment.dart';
import '../ui/design.dart';
import '../settings/settings_page.dart';
import '../settings/settings_sheet.dart';
import 'chat_actions.dart';
import 'attachment_strip.dart';
import 'chat_controller.dart';
import 'composer.dart';
import 'find_in_chat.dart';
import 'history.dart';
import 'model_sheet.dart';
import 'queue_panel.dart';
import 'transcript.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.controller});
  final ChatController controller;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final ChatFindController _findController = ChatFindController();

  ChatController get controller => widget.controller;

  // Announcement tracking: completion and failure are announced once, without
  // moving focus away from the draft.
  String? _announcedChatId;
  bool _wasStreaming = false;
  ChatFailure? _announcedFailure;

  @override
  void initState() {
    super.initState();
    controller.addListener(_announceChanges);
  }

  @override
  void didUpdateWidget(ChatScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_announceChanges);
      widget.controller.addListener(_announceChanges);
    }
  }

  @override
  void dispose() {
    controller.removeListener(_announceChanges);
    _findController.dispose();
    super.dispose();
  }

  void _announceChanges() {
    if (!mounted) return;
    final chatId = controller.conversation?.id;
    final streaming = controller.isStreaming;
    final failure = controller.conversationFailure;
    String? message;
    if (chatId == _announcedChatId) {
      if (failure != null && failure != _announcedFailure) {
        message = failure.message;
      } else if (_wasStreaming && !streaming && failure == null) {
        message = 'Response complete.';
      }
    }
    _announcedChatId = chatId;
    _wasStreaming = streaming;
    _announcedFailure = failure;
    if (message != null) {
      SemanticsService.sendAnnouncement(
        View.of(context),
        message,
        Directionality.of(context),
      );
    }
  }

  /// Opens the connection form directly. Returns true only when Save and
  /// connect succeeded.
  Future<bool> _openConnectionForm({ServerProfile? profile}) =>
      _openServerSettings(); // WIRE: showConnectionForm(context, controller, profile: profile)

  /// Interim entry until the direct connection form is wired.
  Future<bool> _openServerSettings() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsSheet(
          controller: controller,
          section: SettingsSection.servers,
        ),
      ),
    );
    return controller.conversationConnected;
  }

  /// First connection: form, then model selection when no valid model is
  /// configured; the picker returns to the chat with its destination shown.
  Future<void> _connectServer() async {
    final connected = await _openConnectionForm();
    if (!connected || !mounted) return;
    if (controller.conversationConnected && controller.selectedModel == null) {
      await showModelSheet(context, controller);
    }
  }

  Future<bool> _newChat(BuildContext context) async {
    if (controller.conversation == null && controller.hasDraft) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Discard this draft?'),
          content: const Text(
            'Your unsent message and attachments will be removed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Discard'),
            ),
          ],
        ),
      );
      if (discard != true) return false;
      await controller.discardCurrentDraft();
    } else {
      await controller.newConversation();
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final media = MediaQuery.of(context);
      // Compact chrome when the keyboard or landscape leaves little height;
      // grow with the header's two lines so scaled text is never clipped.
      final shortScreen =
          media.size.height - media.viewInsets.bottom - media.padding.top < 480;
      final toolbarHeight = math.max(
        shortScreen ? 52.0 : 64.0,
        media.textScaler.scale(16) * 1.3 +
            media.textScaler.scale(12) * 1.35 +
            Design.space2,
      );
      return Scaffold(
        drawerScrimColor: Design.ink.withValues(alpha: .54),
        drawer: _HistoryDrawer(controller: controller, onNewChat: _newChat),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leadingWidth: Design.gutter + Design.target,
          toolbarHeight: toolbarHeight,
          leading: Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.only(left: Design.gutter),
              child: Center(
                child: RoundAction(
                  label: 'Open chats',
                  icon: 'menu',
                  onPressed: () {
                    FocusManager.instance.primaryFocus?.unfocus();
                    Scaffold.of(context).openDrawer();
                  },
                ),
              ),
            ),
          ),
          titleSpacing: 0,
          centerTitle: true,
          title: _ChatHeaderTitle(controller: controller),
          actions: [
            RoundAction(
              label: 'New chat',
              icon: 'compose',
              onPressed: () => _newChat(context),
            ),
            if (controller.conversation != null) ...[
              const SizedBox(width: 6),
              RoundAction(
                label: 'Chat actions',
                icon: 'more',
                onPressed: () => showChatActions(
                  context,
                  controller,
                  controller.conversation!,
                  onFind: _findController.open,
                ),
              ),
            ],
            const SizedBox(width: Design.gutter),
          ],
        ),
        body: _ChatBody(
          controller: controller,
          findController: _findController,
          onConnectServer: _connectServer,
          onEditConnection: () =>
              _openConnectionForm(profile: controller.conversationProfile),
        ),
      );
    },
  );
}

/// Model selection plus the chat's destination and connection status as a
/// secondary line. Text truncates visually; semantics keep the full values.
class _ChatHeaderTitle extends StatelessWidget {
  const _ChatHeaderTitle({required this.controller});
  final ChatController controller;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final status = controller.conversationConnectionStatus;
    final destination = status == ConnectionStatus.notConfigured
        ? status.label
        : '${controller.conversationDestinationName} · ${status.label}';
    final model = controller.conversationConnected
        ? (controller.selectedModel ?? 'Choose model')
        : (controller.conversation?.selectedModel ?? 'MobileLlama');
    return TextButton(
      onPressed: () => showModelSheet(context, controller),
      style: TextButton.styleFrom(
        foregroundColor: colors.onSurface,
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.symmetric(horizontal: 4),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  model,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 5),
              const DesignIcon('down', size: 15),
            ],
          ),
          Semantics(
            liveRegion: true,
            child: Text(
              destination,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatBody extends StatelessWidget {
  const _ChatBody({
    required this.controller,
    required this.findController,
    required this.onConnectServer,
    required this.onEditConnection,
  });
  final ChatController controller;
  final ChatFindController findController;
  final Future<void> Function() onConnectServer;
  final Future<bool> Function() onEditConnection;

  /// Body height below which queue and attachment previews collapse to
  /// summaries and the composer uses compact padding.
  static const double _shortHeight = 420;

  /// Recovery actions that concern the connection rather than one request.
  static const Set<ChatRecoveryAction> _connectionActions = {
    ChatRecoveryAction.retryConnection,
    ChatRecoveryAction.editConnection,
    ChatRecoveryAction.openSystemSettings,
  };

  bool get _hasAttachments =>
      controller.pendingImageReferences.isNotEmpty ||
      controller.pendingDocuments.isNotEmpty;

  bool get _imagesUnsupported =>
      controller.pendingImageReferences.isNotEmpty &&
      controller.imagesSupported == false;

  bool get _checking =>
      controller.conversationConnectionStatus == ConnectionStatus.checking;

  /// Why Send/Queue is unavailable, or null when it is available.
  String? get _submitUnavailableReason =>
      switch (controller.submitAvailability) {
        SubmitAvailability.noConnection => 'Connect a server to send',
        SubmitAvailability.unavailable =>
          '${controller.conversationDestinationName} is unavailable',
        SubmitAvailability.noModel => 'Choose a model to send',
        SubmitAvailability.localMutation => 'Saving…',
        SubmitAvailability.streaming ||
        SubmitAvailability.queuePaused ||
        SubmitAvailability.ready =>
          _imagesUnsupported
              ? 'This model can’t read images. Remove them or choose another model.'
              : null,
      };

  /// The chat's request failure, when it belongs to a visible message.
  bool _failureOnMessage(ChatFailure failure) =>
      failure.messageId != null &&
      controller.transcriptMessages.any(
        (message) => message.id == failure.messageId,
      );

  /// A profile-level failure shown as a compact banner, unless the chat's
  /// own failure already says the same thing.
  ChatFailure? get _connectionBanner {
    final failure = controller.conversationConnectionFailure;
    if (failure == null) return null;
    if (failure.message == controller.conversationFailure?.message) {
      return null;
    }
    return failure;
  }

  Future<void> _connect() => controller.connectConversation();

  Future<void> _runAction(
    BuildContext context,
    ChatRecoveryAction action,
    ChatFailure failure,
  ) async {
    switch (action) {
      case ChatRecoveryAction.retryConnection:
        await controller.connectConversation();
      case ChatRecoveryAction.editConnection:
        await onEditConnection();
      case ChatRecoveryAction.openSystemSettings:
        // UIApplication.openSettingsURLString on iOS.
        await launchUrl(Uri.parse('app-settings:'));
      case ChatRecoveryAction.retry:
        final target = _retryTarget(failure);
        if (target != null) await controller.retryAssistant(target);
      case ChatRecoveryAction.resume:
        await controller.resumeQueue();
      case ChatRecoveryAction.chooseModel:
        await showModelSheet(context, controller);
      case ChatRecoveryAction.refreshModels:
        await controller.refreshModelList(profileId: failure.profileId);
      case ChatRecoveryAction.removeAttachment:
        await _showAttachments(context);
      case ChatRecoveryAction.retrySave:
        await controller.retryDraftSave();
    }
  }

  /// The retryable answer for a failure, or null when Retry is unavailable.
  String? _retryTarget(ChatFailure failure) {
    final messages = controller.transcriptMessages;
    final latest = messages.lastWhere(
      (message) => message.role == TranscriptRole.assistant,
      orElse: () => const TranscriptMessageView(
        id: '',
        role: TranscriptRole.system,
        content: '',
      ),
    );
    if (latest.id.isEmpty || !latest.canRetry) return null;
    if (latest.status != TranscriptStatus.failed &&
        latest.status != TranscriptStatus.interrupted) {
      return null;
    }
    return latest.id;
  }

  /// Actions offered for [failure]; [nearMessage] omits Retry because the
  /// affected answer shows its own Retry button.
  List<ChatRecoveryAction> _actionsFor(
    ChatFailure failure, {
    bool nearMessage = false,
    bool connectionOnly = false,
  }) => [
    for (final action in failure.actions)
      if ((!connectionOnly || _connectionActions.contains(action)) &&
          !(action == ChatRecoveryAction.retry &&
              (nearMessage || _retryTarget(failure) == null)) &&
          !(action == ChatRecoveryAction.removeAttachment &&
              !_hasAttachments) &&
          !(action == ChatRecoveryAction.resume && !controller.queuePaused))
        action,
  ];

  Widget _failureNotice(
    BuildContext context,
    ChatFailure failure, {
    required VoidCallback onDismiss,
    bool nearMessage = false,
    bool connectionOnly = false,
  }) => _FailureNotice(
    failure: failure,
    actions: _actionsFor(
      failure,
      nearMessage: nearMessage,
      connectionOnly: connectionOnly,
    ),
    busy: _checking,
    onAction: (action) => _runAction(context, action, failure),
    onDismiss: onDismiss,
  );

  List<TranscriptMessageView> get _transcriptMessages {
    final messages = controller.transcriptMessages;
    final id = controller.conversation?.id;
    if (id == null || !controller.hasRecoveryCheckpoint(id)) return messages;
    final latest = messages.lastIndexWhere(
      (message) => message.role == TranscriptRole.assistant,
    );
    if (latest < 0) return messages;
    return [
      for (var index = 0; index < messages.length; index++)
        index == latest
            ? messages[index].copyWith(canRestorePrevious: true)
            : messages[index],
    ];
  }

  Future<void> _showQueue(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => SafeArea(
      top: false,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => controller.queuedPrompts.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(Design.gutter),
                child: Text('No queued messages.'),
              )
            : QueuedPromptPanel(
                prompts: controller.queuedPrompts,
                paused: controller.queuePaused,
                maxHeight: MediaQuery.sizeOf(context).height * .75,
                onResume: controller.resumeQueue,
                onEdit: controller.editQueuedPrompt,
                onRemove: controller.removeQueuedPrompt,
                onReorder: controller.reorderQueuedPrompts,
              ),
      ),
    ),
  );

  Future<void> _showAttachments(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        builder: (context) => SafeArea(
          top: false,
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: Design.gutter),
                  child: Column(
                    children: <Widget>[
                      SheetHandle(),
                      SheetHeading(
                        title: 'Attachments',
                        closeLabel: 'Close attachments',
                      ),
                    ],
                  ),
                ),
                if (!_hasAttachments)
                  const Padding(
                    padding: EdgeInsets.all(Design.gutter),
                    child: Text('No attachments.'),
                  ),
                ..._attachmentPreviews(context),
                const SizedBox(height: Design.gutter),
              ],
            ),
          ),
        ),
      );

  List<Widget> _attachmentPreviews(BuildContext context) => <Widget>[
    if (controller.pendingImageReferences.isNotEmpty)
      PendingImageStrip(
        references: controller.pendingImageReferences,
        onRemove: controller.removePendingImage,
      ),
    if (_imagesUnsupported)
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: Design.gutter),
        child: Text(
          'Remove the image or choose a model that supports images.',
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.error),
        ),
      ),
    if (controller.pendingDocuments.isNotEmpty)
      _PendingDocuments(
        documents: controller.pendingDocuments,
        onRemove: controller.removePendingDocument,
      ),
  ];

  /// Setup and model prompts shown above the composer.
  List<Widget> _statusLines(BuildContext context, {required bool short}) {
    final colors = Theme.of(context).colorScheme;
    final profileId = controller.conversationProfile.id;
    final failure = controller.conversationFailure;
    return <Widget>[
      // A request failure that is not attached to a visible message.
      if (failure != null && !_failureOnMessage(failure))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Design.gutter),
          child: _failureNotice(
            context,
            failure,
            onDismiss: () =>
                controller.dismissFailure(controller.conversation?.id ?? ''),
          ),
        ),
      // An unconfigured new chat shows its connect action in the welcome.
      if (controller.conversationProfile.configured &&
          !controller.conversationConnected &&
          _connectionBanner == null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Design.gutter),
          child: TextButton(
            onPressed: controller.canChangeContext && !_checking
                ? _connect
                : null,
            child: Text(
              _checking
                  ? 'Connecting…'
                  : 'Connect to ${controller.conversationDestinationName} to continue',
            ),
          ),
        )
      else if (controller.conversationConnected &&
          controller.models.isEmpty &&
          !controller.modelListRefreshing(profileId))
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Design.gutter),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                controller.modelListError(profileId)?.message ??
                    'Server is reachable but has no available models',
              ),
              TextButton(
                onPressed: () =>
                    controller.refreshModelList(profileId: profileId),
                child: Text(
                  controller.modelListError(profileId) == null
                      ? 'Refresh'
                      : 'Retry',
                ),
              ),
            ],
          ),
        )
      else if (controller.conversationConnected &&
          controller.selectedModel == null)
        TextButton(
          onPressed: () => showModelSheet(context, controller),
          child: const Text('Choose a model to continue'),
        ),
      if (!short)
        if (controller.contextNotice case final notice?)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Design.gutter,
              Design.space1,
              Design.gutter,
              Design.space2,
            ),
            child: Text(
              notice,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
    ];
  }

  /// Compact banners for connection/setup-level failures, local save
  /// failures, and any other chat error. Request failures render near their
  /// message instead.
  List<Widget> _banners(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final general = generalChatError(controller);
    return <Widget>[
      if (_connectionBanner case final failure?)
        _failureNotice(
          context,
          failure,
          connectionOnly: true,
          onDismiss: controller.clearError,
        ),
      if (controller.draftPersistenceFailure case final failure?)
        _failureNotice(context, failure, onDismiss: controller.clearError),
      if (general != null)
        Row(
          children: [
            Expanded(
              child: Text(
                general,
                style: TextStyle(fontSize: 14, color: colors.error),
              ),
            ),
            IconButton(
              tooltip: 'Dismiss error',
              onPressed: controller.clearError,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    if (!controller.initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final chatFailure = controller.conversationFailure;
    return AnimatedBuilder(
      animation: findController,
      builder: (context, _) => Column(
        children: [
          for (final banner in _banners(context))
            Padding(
              padding: const EdgeInsets.fromLTRB(
                Design.gutter,
                Design.space1,
                Design.gutter,
                0,
              ),
              child: banner,
            ),
          if (findController.isOpen) ChatFindBar(controller: findController),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                final short = height < _shortHeight;
                return Column(
                  children: [
                    Expanded(
                      child: ChatTranscript(
                        key: PageStorageKey(
                          'transcript-${controller.conversation?.id ?? 'new'}',
                        ),
                        messages: _transcriptMessages,
                        findController: findController,
                        findScope: Object.hash(
                          controller.conversation?.id,
                          controller.draftScopeRevision,
                        ),
                        onRetry: controller.conversationConnected
                            ? (message) => controller.retryAssistant(message.id)
                            : null,
                        onEditAndResend: (message, text) =>
                            controller.editAndResend(message.id, text),
                        onRegenerate: (message) =>
                            controller.regenerateAssistant(message.id),
                        onRestorePrevious: (_) => restorePreviousConversation(
                          context,
                          controller,
                          controller.conversation!.id,
                        ),
                        canMutate: () => controller.canSend,
                        messageFooter: (message) =>
                            chatFailure != null &&
                                chatFailure.messageId == message.id
                            ? _failureNotice(
                                context,
                                chatFailure,
                                nearMessage: true,
                                onDismiss: () => controller.dismissFailure(
                                  controller.conversation!.id,
                                ),
                              )
                            : null,
                        emptyState: _Welcome(
                          setup:
                              controller.submitAvailability ==
                              SubmitAvailability.noConnection,
                          connecting: _checking,
                          onConnect: controller.canChangeContext
                              ? onConnectServer
                              : null,
                        ),
                      ),
                    ),
                    // The bottom region never exceeds the body. In a short
                    // viewport it may take all of it; the transcript yields.
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: short ? height : height * .6,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          ..._statusLines(context, short: short),
                          if (short)
                            _DraftSummary(
                              queued: controller.queuedPrompts.length,
                              queuePaused: controller.queuePaused,
                              attachments:
                                  controller.pendingImageReferences.length +
                                  controller.pendingDocuments.length,
                              onOpenQueue: () => _showQueue(context),
                              onOpenAttachments: () =>
                                  _showAttachments(context),
                            )
                          else ...[
                            if (controller.queuedPrompts.isNotEmpty)
                              QueuedPromptPanel(
                                prompts: controller.queuedPrompts,
                                paused: controller.queuePaused,
                                maxHeight: height * .3,
                                onResume: controller.resumeQueue,
                                onEdit: controller.editQueuedPrompt,
                                onRemove: controller.removeQueuedPrompt,
                                onReorder: controller.reorderQueuedPrompts,
                              ),
                            ..._attachmentPreviews(context),
                          ],
                          Flexible(
                            child: ChatComposer(
                              compact: short,
                              draftScopeRevision: controller.draftScopeRevision,
                              draftText: controller.draftText,
                              onDraftChanged: controller.setDraftText,
                              isStreaming: controller.isStreaming,
                              isQueueing:
                                  controller.isStreaming ||
                                  controller.queuedPrompts.isNotEmpty,
                              // Local editing survives an unreachable server;
                              // only a local mutation briefly holds it.
                              editable: controller.canEditDraft,
                              canSubmit:
                                  controller.canSubmit && !_imagesUnsupported,
                              submitUnavailableReason: _submitUnavailableReason,
                              hasAttachments: _hasAttachments,
                              imagesEnabled:
                                  controller.canEditDraft &&
                                  controller.imagesSupported != false,
                              onPickImage: controller.pickImage,
                              onTakePhoto: () =>
                                  controller.pickImage(camera: true),
                              onPickDocument: controller.pickDocument,
                              onSend: controller.send,
                              onStop: controller.stop,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A classified failure with its recovery actions. Dismiss hides only the
/// presentation; the failed status and preserved content remain.
class _FailureNotice extends StatelessWidget {
  const _FailureNotice({
    required this.failure,
    required this.actions,
    required this.busy,
    required this.onAction,
    required this.onDismiss,
  });

  final ChatFailure failure;
  final List<ChatRecoveryAction> actions;
  final bool busy;
  final ValueChanged<ChatRecoveryAction> onAction;
  final VoidCallback onDismiss;

  static String _label(ChatRecoveryAction action) => switch (action) {
    ChatRecoveryAction.retryConnection => 'Retry connection',
    ChatRecoveryAction.editConnection => 'Edit connection',
    ChatRecoveryAction.openSystemSettings => 'Open Settings',
    ChatRecoveryAction.retry => 'Retry',
    ChatRecoveryAction.resume => 'Resume',
    ChatRecoveryAction.chooseModel => 'Choose model',
    ChatRecoveryAction.refreshModels => 'Refresh models',
    ChatRecoveryAction.removeAttachment => 'Remove attachment',
    ChatRecoveryAction.retrySave => 'Retry save',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: .35),
        border: Border.all(color: colors.error.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(Design.radiusMedium),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Design.space3, 0, 0, Design.space1),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: Design.space3),
                    child: Text(
                      failure.message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurface,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  constraints: const BoxConstraints.tightFor(
                    width: Design.target,
                    height: Design.target,
                  ),
                  onPressed: onDismiss,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
            if (actions.isNotEmpty)
              Wrap(
                spacing: Design.space1,
                children: <Widget>[
                  for (final action in actions)
                    TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(Design.target, Design.target),
                        padding: const EdgeInsets.symmetric(
                          horizontal: Design.space2,
                        ),
                      ),
                      onPressed:
                          busy && action == ChatRecoveryAction.retryConnection
                          ? null
                          : () => onAction(action),
                      child: Text(
                        busy && action == ChatRecoveryAction.retryConnection
                            ? 'Connecting…'
                            : _label(action),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

/// Collapsed queue and attachment previews for short viewports. Each summary
/// opens the full editing surface.
class _DraftSummary extends StatelessWidget {
  const _DraftSummary({
    required this.queued,
    required this.queuePaused,
    required this.attachments,
    required this.onOpenQueue,
    required this.onOpenAttachments,
  });

  final int queued;
  final bool queuePaused;
  final int attachments;
  final VoidCallback onOpenQueue;
  final VoidCallback onOpenAttachments;

  @override
  Widget build(BuildContext context) {
    if (queued == 0 && attachments == 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Design.gutter,
        Design.space1,
        Design.gutter,
        0,
      ),
      child: Wrap(
        spacing: Design.space2,
        runSpacing: Design.space1,
        children: <Widget>[
          if (queued > 0)
            _SummaryButton(
              label: queuePaused ? '$queued queued · paused' : '$queued queued',
              icon: Icons.schedule_send_outlined,
              onPressed: onOpenQueue,
            ),
          if (attachments > 0)
            _SummaryButton(
              label: attachments == 1
                  ? '1 attachment'
                  : '$attachments attachments',
              icon: Icons.attach_file_rounded,
              onPressed: onOpenAttachments,
            ),
        ],
      ),
    );
  }
}

class _SummaryButton extends StatelessWidget {
  const _SummaryButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(Design.target, Design.target),
      padding: const EdgeInsets.symmetric(horizontal: Design.space3),
      foregroundColor: Theme.of(context).colorScheme.onSurface,
      side: BorderSide(color: Design.line(context)),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Design.radiusMedium),
      ),
    ),
    icon: Icon(icon, size: 18),
    label: Text(label),
  );
}

class _Welcome extends StatelessWidget {
  const _Welcome({
    required this.setup,
    required this.connecting,
    required this.onConnect,
  });

  /// True when there is no usable connection for this new chat: explain the
  /// app's purpose and offer the connect action.
  final bool setup;
  final bool connecting;
  final VoidCallback? onConnect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ExcludeSemantics(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(17),
                        child: Image.asset(
                          'assets/mobilellama-icon.png',
                          width: 72,
                          height: 72,
                        ),
                      ),
                    ),
                    SizedBox(height: setup ? Design.space5 : 42),
                    Semantics(
                      header: true,
                      child: Text(
                        setup
                            ? 'Chat with models on your own server.'
                            : 'What can I\nhelp with?',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: setup ? 26 : 32,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: setup ? -.5 : -.8,
                        ),
                      ),
                    ),
                    if (setup) ...[
                      const SizedBox(height: Design.space3),
                      Text(
                        'Connect Ollama or an OpenAI-compatible API. '
                        'Models run on that server.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: Design.space5),
                      FilledButton(
                        onPressed: onConnect,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: Design.space5,
                          ),
                        ),
                        child: Text(
                          connecting ? 'Connecting…' : 'Connect a server',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HistoryDrawer extends StatelessWidget {
  const _HistoryDrawer({required this.controller, required this.onNewChat});
  final ChatController controller;
  final Future<bool> Function(BuildContext context) onNewChat;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
    child: Drawer(
      width: (MediaQuery.sizeOf(context).width * .82).clamp(0, 420),
      semanticLabel: 'Chats',
      backgroundColor: Design.panel(context),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.horizontal(right: Radius.circular(24)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final chats = controller.visibleHistory;
              final groups = <String, List<Conversation>>{};
              for (final chat in chats) {
                final group = chat.isPinned
                    ? 'Pinned'
                    : chatDateGroup(chat.updatedAt);
                (groups[group] ??= []).add(chat);
              }
              return Column(
                children: [
                  Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'MobileLlama',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      RoundAction(
                        label: 'Search chats',
                        icon: 'search',
                        onPressed: () async {
                          final opened = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  ChatHistoryPage(controller: controller),
                            ),
                          );
                          if (opened == true && context.mounted) {
                            Navigator.pop(context);
                          }
                        },
                      ),
                    ],
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.only(top: 14, bottom: 14),
                      children: [
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const DesignIcon('servers'),
                          horizontalTitleGap: 13,
                          title: const Text(
                            'Servers',
                            style: TextStyle(fontSize: 17),
                          ),
                          onTap: () => Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  SettingsSheet(controller: controller),
                            ),
                          ),
                        ),
                        if (chats.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 24),
                            child: Text('No chats yet.'),
                          ),
                        for (final label in [
                          'Pinned',
                          'Today',
                          'Previous 7 days',
                          'Older',
                        ])
                          if (groups.containsKey(label)) ...[
                            Padding(
                              padding: const EdgeInsets.only(
                                top: 24,
                                bottom: 6,
                              ),
                              child: Semantics(
                                header: true,
                                child: Text(
                                  label,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ),
                            for (final chat in groups[label]!)
                              ChatHistoryRow(
                                chat: chat,
                                controller: controller,
                                onTap: () async {
                                  await controller.openConversation(chat.id);
                                  if (context.mounted &&
                                      controller.conversation?.id == chat.id) {
                                    Navigator.pop(context);
                                  }
                                },
                              ),
                          ],
                      ],
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            style: FilledButton.styleFrom(
                              minimumSize: const Size(0, 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 19,
                              ),
                              textStyle: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .onSurface,
                              foregroundColor: Theme.of(context)
                                  .colorScheme
                                  .surface,
                              shape: const StadiumBorder(),
                            ),
                            onPressed: () async {
                              final opened = await onNewChat(context);
                              if (opened && context.mounted) {
                                Navigator.pop(context);
                              }
                            },
                            icon: const DesignIcon('compose', size: 19),
                            label: const Text('New chat'),
                          ),
                        ),
                      ),
                      RoundAction(
                        label: 'Settings',
                        icon: 'settings',
                        onPressed: () async {
                          final opened = await Navigator.push<bool>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  SettingsPage(controller: controller),
                            ),
                          );
                          if (opened == true && context.mounted) {
                            Navigator.pop(context);
                          }
                        },
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _PendingDocuments extends StatelessWidget {
  const _PendingDocuments({required this.documents, required this.onRemove});

  final List<DocumentAttachment> documents;
  final Future<void> Function(String id) onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(
          Design.gutter,
          Design.space1,
          Design.gutter,
          Design.space1,
        ),
        itemCount: documents.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final document = documents[index];
          return Container(
            constraints: const BoxConstraints(maxWidth: 260),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(color: Design.line(context)),
              borderRadius: BorderRadius.circular(Design.radiusMedium),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Padding(
                  padding: EdgeInsets.only(left: 10),
                  child: Icon(Icons.description_outlined, size: 18),
                ),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    document.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'Remove ${document.name}',
                  constraints: const BoxConstraints.tightFor(
                    width: 44,
                    height: 44,
                  ),
                  onPressed: () => onRemove(document.id),
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
