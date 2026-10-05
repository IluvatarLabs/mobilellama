import 'dart:async';

import 'package:flutter/material.dart';

import '../chat/composer.dart';
import '../chat/transcript.dart';
import 'socket.dart';
import 'temporary.dart';
import 'workspace.dart';

class WebUiTemporaryScreen extends StatefulWidget {
  const WebUiTemporaryScreen({super.key, required this.workspace});
  final WebUiWorkspace workspace;
  @override
  State<WebUiTemporaryScreen> createState() => _WebUiTemporaryScreenState();
}

class _WebUiTemporaryScreenState extends State<WebUiTemporaryScreen>
    with WidgetsBindingObserver {
  late final chat = WebUiTemporaryChat(
    widget.workspace.session,
    WebUiSocket(widget.workspace.session),
    model: widget.workspace.model,
  );
  late final opening = chat.initialize(
    heartbeatSeconds:
        (widget.workspace.serverConfiguration['features']
            as Map?)?['websocket_heartbeat_interval'],
  );
  final editor = TextEditingController();
  bool closing = false, canPop = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      chat.setForeground(state == AppLifecycleState.resumed);
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    chat.dispose();
    editor.dispose();
    super.dispose();
  }

  Future<void> exit({bool save = false}) async {
    if (closing) return;
    if (!save) {
      final choice = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Close temporary chat?'),
          content: const Text(
            'Discard ends this session and its queue. Save copies visible messages to server history. Your unsent draft stays in this app on this device.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Keep editing'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, 'discard'),
              child: const Text('Discard'),
            ),
            FilledButton(
              onPressed: !chat.canSave
                  ? null
                  : () => Navigator.pop(context, 'save'),
              child: const Text('Save'),
            ),
          ],
        ),
      );
      if (!mounted || choice == null) return;
      save = choice == 'save';
    }
    setState(() => closing = true);
    try {
      String? saved;
      if (save) {
        saved = await chat.save(widget.workspace.accounts);
      } else if (chat.running) {
        await chat.stop();
      }
      if (!mounted) return;
      setState(() => canPop = true);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.pop(context, saved);
      });
    } catch (error) {
      if (mounted) {
        setState(() => closing = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(exit());
    },
    child: FutureBuilder<void>(
      future: opening,
      builder: (context, snapshot) => AnimatedBuilder(
        animation: chat,
        builder: (context, _) => Scaffold(
          appBar: AppBar(
            leading: IconButton(
              tooltip: 'Exit temporary chat',
              onPressed: closing ? null : () => exit(),
              icon: const Icon(Icons.close),
            ),
            title: const Text('Temporary chat'),
            actions: [
              TextButton(
                onPressed:
                    closing ||
                        !chat.canSave ||
                        snapshot.hasError ||
                        snapshot.connectionState != ConnectionState.done
                    ? null
                    : () => exit(save: true),
                child: const Text('Save'),
              ),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Text(
                        'Text only · Not saved in history unless you choose Save. No tools or memory are requested. Your server’s model settings still apply, and it may retain logs.',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (snapshot.connectionState != ConnectionState.done)
                      const LinearProgressIndicator(),
                    if (snapshot.hasError || chat.problem != null)
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: Text(
                          '${snapshot.error ?? chat.problem}',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: DropdownButtonFormField<String>(
                        initialValue: chat.model.isEmpty ? null : chat.model,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Model'),
                        items: [
                          for (final model in widget.workspace.models)
                            DropdownMenuItem(
                              value: model['id'] as String,
                              child: Text(
                                model['name'] as String? ??
                                    model['id'] as String,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: chat.running || chat.savePending || closing
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => chat.model = value);
                                }
                              },
                      ),
                    ),
                    Expanded(
                      child: ChatTranscript(
                        messages: chat.messages,
                        emptyState: const Center(
                          child: Text('Start a temporary conversation.'),
                        ),
                      ),
                    ),
                    if (chat.queue.isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 140),
                        child: ListView(
                          shrinkWrap: true,
                          children: [
                            if (chat.queuePaused)
                              TextButton(
                                onPressed: chat.canSend
                                    ? chat.resumeQueue
                                    : null,
                                child: const Text('Resume queued messages'),
                              ),
                            for (var i = 0; i < chat.queue.length; i++)
                              ListTile(
                                dense: true,
                                title: Text(
                                  chat.queue[i].text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                trailing: IconButton(
                                  tooltip: 'Remove queued message',
                                  icon: const Icon(Icons.close),
                                  onPressed: () => chat.removeQueued(i),
                                ),
                              ),
                          ],
                        ),
                      ),
                    Flexible(
                      flex: 0,
                      child: ChatComposer(
                        controller: editor,
                        draftText: chat.draft,
                        editable:
                            !closing &&
                            !chat.saving &&
                            !chat.savePending &&
                            !chat.session.locked,
                        canSubmit: chat.canSend,
                        submitUnavailableReason: 'A live connection is required. Keep or save this text, then start a new temporary chat.',
                        isStreaming: chat.running,
                        isQueueing: chat.running,
                        onDraftChanged: chat.setDraft,
                        onSend: chat.send,
                        onStop: () => unawaited(chat.stop()),
                        imagesEnabled: false,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
