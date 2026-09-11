import 'package:flutter/material.dart';

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

  @override
  void dispose() {
    _findController.dispose();
    super.dispose();
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
      final colors = Theme.of(context).colorScheme;
      return Scaffold(
        drawerScrimColor: Design.ink.withValues(alpha: .54),
        drawer: _HistoryDrawer(controller: controller, onNewChat: _newChat),
        appBar: AppBar(
          automaticallyImplyLeading: false,
          leadingWidth: 58,
          toolbarHeight: 64,
          leading: Builder(
            builder: (context) => Padding(
              padding: const EdgeInsets.only(left: 14),
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
          title: TextButton(
            onPressed: () => showModelSheet(context, controller),
            style: TextButton.styleFrom(
              foregroundColor: colors.onSurface,
              minimumSize: const Size(44, 44),
              padding: const EdgeInsets.symmetric(horizontal: 4),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    controller.conversationConnected
                        ? (controller.selectedModel ?? 'Choose model')
                        : (controller.conversation?.selectedModel ??
                              'MobileLlama'),
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
          ),
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
            const SizedBox(width: 14),
          ],
        ),
        body: _ChatBody(
          controller: controller,
          findController: _findController,
        ),
      );
    },
  );
}

class _ChatBody extends StatelessWidget {
  const _ChatBody({required this.controller, required this.findController});
  final ChatController controller;
  final ChatFindController findController;
  @override
  Widget build(BuildContext context) {
    if (!controller.initialized) {
      return const Center(child: CircularProgressIndicator());
    }
    final colors = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: findController,
      builder: (context, _) => Column(
        children: [
          if (controller.errorMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      controller.errorMessage!,
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
            ),
          if (findController.isOpen) ChatFindBar(controller: findController),
          Expanded(
            child: ChatTranscript(
              key: PageStorageKey(
                'transcript-${controller.conversation?.id ?? 'new'}',
              ),
              messages: controller.transcriptMessages,
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
              canMutate: () => controller.canSend,
              emptyState: const _Welcome(),
            ),
          ),
          if (!controller.conversationConnected)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextButton(
                onPressed: controller.canChangeContext
                    ? () async {
                        if (controller.conversation == null) {
                          await Navigator.push<void>(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  SettingsSheet(controller: controller),
                            ),
                          );
                        } else {
                          await controller.connectConversation();
                        }
                      }
                    : null,
                child: Text(
                  controller.profileMutationBusy
                      ? 'Connecting…'
                      : controller.conversation == null
                      ? 'Connect a server'
                      : 'Connect to ${controller.conversationProfile.name} to continue',
                ),
              ),
            )
          else if (controller.models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('No models returned.'),
                  TextButton(
                    onPressed: controller.canChangeContext
                        ? controller.refreshModels
                        : null,
                    child: const Text('Refresh'),
                  ),
                ],
              ),
            )
          else if (controller.selectedModel == null)
            TextButton(
              onPressed: () => showModelSheet(context, controller),
              child: const Text('Choose an available model to continue'),
            ),
          if (controller.contextNotice case final notice?)
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 4, 18, 8),
              child: Text(
                notice,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: colors.onSurfaceVariant),
              ),
            ),
          if (controller.queuedPrompts.isNotEmpty)
            QueuedPromptPanel(
              prompts: controller.queuedPrompts,
              paused: controller.queuePaused,
              onResume: controller.resumeQueue,
              onEdit: controller.editQueuedPrompt,
              onRemove: controller.removeQueuedPrompt,
              onReorder: controller.reorderQueuedPrompts,
            ),
          if (controller.pendingImageReferences.isNotEmpty)
            PendingImageStrip(
              references: controller.pendingImageReferences,
              onRemove: controller.removePendingImage,
            ),
          if (controller.pendingImageReferences.isNotEmpty &&
              controller.conversationConnected &&
              controller.selectedModel != null &&
              !controller.supportsImages)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'Remove the image or choose a model that supports images.',
              ),
            ),
          if (controller.pendingDocuments.isNotEmpty)
            _PendingDocuments(
              documents: controller.pendingDocuments,
              onRemove: controller.removePendingDocument,
            ),
          ChatComposer(
            draftScopeRevision: controller.draftScopeRevision,
            draftText: controller.draftText,
            onDraftChanged: controller.setDraftText,
            isStreaming: controller.isStreaming,
            isQueueing:
                controller.isStreaming || controller.queuedPrompts.isNotEmpty,
            enabled:
                controller.canQueueOrSend &&
                !controller.isSubmitting &&
                !controller.conversationMutationBusy,
            sendEnabled:
                controller.canQueueOrSend &&
                (controller.pendingImageReferences.isEmpty ||
                    controller.supportsImages),
            hasAttachments:
                controller.pendingImageReferences.isNotEmpty ||
                controller.pendingDocuments.isNotEmpty,
            imagesEnabled:
                controller.conversationConnected &&
                controller.selectedModel != null &&
                controller.supportsImages,
            onPickImage: controller.pickImage,
            onTakePhoto: () => controller.pickImage(camera: true),
            onPickDocument: controller.pickDocument,
            onSend: controller.send,
            onStop: controller.stop,
          ),
        ],
      ),
    );
  }
}

class _Welcome extends StatelessWidget {
  const _Welcome();
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 18),
            child:
                !Design.dark(context) &&
                    MediaQuery.textScalerOf(context).scale(17) < 24
                ? Image.asset(
                    'assets/welcome.png',
                    width: 236,
                    semanticLabel: 'What can I help with?',
                  )
                : ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 290),
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
                        const SizedBox(height: 42),
                        const Text(
                          'What can I\nhelp with?',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 32,
                            height: 1.15,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.8,
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
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
        padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
        itemCount: documents.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final document = documents[index];
          return Container(
            constraints: const BoxConstraints(maxWidth: 260),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              border: Border.all(color: Design.line(context)),
              borderRadius: BorderRadius.circular(14),
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
