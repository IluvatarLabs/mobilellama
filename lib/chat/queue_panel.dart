import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../domain/queued_prompt.dart';
import '../ui/design.dart';

class QueuedPromptPanel extends StatefulWidget {
  const QueuedPromptPanel({
    super.key,
    required this.prompts,
    required this.paused,
    required this.onResume,
    required this.onEdit,
    required this.onRemove,
    required this.onReorder,
  });

  final List<QueuedPrompt> prompts;
  final bool paused;
  final Future<void> Function() onResume;
  final Future<void> Function(String id, String text) onEdit;
  final Future<void> Function(String id) onRemove;
  final Future<void> Function(List<String> ids) onReorder;

  @override
  State<QueuedPromptPanel> createState() => _QueuedPromptPanelState();
}

class _QueuedPromptPanelState extends State<QueuedPromptPanel> {
  late List<QueuedPrompt> _items = List.of(widget.prompts);
  bool _busy = false;

  @override
  void didUpdateWidget(QueuedPromptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final current = _items.map((item) => item.id).join('\u0000');
    final incoming = widget.prompts.map((item) => item.id).join('\u0000');
    if (current != incoming || !_sameContents(_items, widget.prompts)) {
      _items = List.of(widget.prompts);
    }
  }

  bool _sameContents(List<QueuedPrompt> a, List<QueuedPrompt> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index].id != b[index].id || a[index].text != b[index].text) {
        return false;
      }
    }
    return true;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resume() async {
    try {
      await widget.onResume();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('The queued messages could not resume.')),
      );
    }
  }

  Future<void> _edit(QueuedPrompt prompt) async {
    final text = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: false,
      builder: (context) => _QueuedPromptEditor(prompt: prompt),
    );
    if (text == null || !mounted) return;
    await _run(() => widget.onEdit(prompt.id, text));
  }

  Future<void> _clear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear queued messages?'),
        content: const Text(
          'The queued text and attachments will be removed from this chat.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ids = _items.map((item) => item.id).toList(growable: false);
    await _run(() async {
      for (final id in ids) {
        await widget.onRemove(id);
      }
    });
  }

  void _reorder(int oldIndex, int newIndex) {
    if (_busy) return;
    final next = List<QueuedPrompt>.of(_items);
    final moved = next.removeAt(oldIndex);
    next.insert(newIndex, moved);
    setState(() => _items = next);
    _run(
      () =>
          widget.onReorder(next.map((item) => item.id).toList(growable: false)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 2),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * .38,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            border: Border.all(color: Design.line(context)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 6, 4),
                child: _QueueHeader(
                  count: _items.length,
                  paused: widget.paused,
                  enabled: !_busy,
                  onResume: () => unawaited(_resume()),
                  onClear: _clear,
                ),
              ),
              Divider(height: 1, color: Design.line(context, .16)),
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  buildDefaultDragHandles: false,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _items.length,
                  onReorderItem: _reorder,
                  proxyDecorator: (child, _, animation) => Material(
                    color: colors.surfaceContainerHigh,
                    elevation: 2,
                    borderRadius: BorderRadius.circular(10),
                    child: child,
                  ),
                  itemBuilder: (context, index) {
                    final prompt = _items[index];
                    return _QueuedPromptRow(
                      key: ValueKey<String>(prompt.id),
                      index: index,
                      prompt: prompt,
                      enabled: !_busy,
                      onEdit: () => _edit(prompt),
                      onRemove: () => _run(() => widget.onRemove(prompt.id)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _QueueHeader extends StatelessWidget {
  const _QueueHeader({
    required this.count,
    required this.paused,
    required this.enabled,
    required this.onResume,
    required this.onClear,
  });

  final int count;
  final bool paused;
  final bool enabled;
  final VoidCallback onResume;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final title = Text(
      'Queued ($count)',
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(fontWeight: FontWeight.w700),
    );
    final actions = Wrap(
      spacing: 0,
      children: <Widget>[
        if (paused)
          TextButton.icon(
            onPressed: enabled ? onResume : null,
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('Resume'),
          ),
        TextButton(
          onPressed: enabled ? onClear : null,
          child: const Text('Clear all'),
        ),
      ],
    );
    if (MediaQuery.textScalerOf(context).scale(14) > 18) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 4),
            child: title,
          ),
          Align(alignment: Alignment.centerRight, child: actions),
        ],
      );
    }
    return Row(
      children: <Widget>[
        Expanded(child: title),
        actions,
      ],
    );
  }
}

class _QueuedPromptRow extends StatelessWidget {
  const _QueuedPromptRow({
    super.key,
    required this.index,
    required this.prompt,
    required this.enabled,
    required this.onEdit,
    required this.onRemove,
  });

  final int index;
  final QueuedPrompt prompt;
  final bool enabled;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final attachmentCount =
        prompt.imageReferences.length + prompt.documents.length;
    return Semantics(
      label: 'Queued message ${index + 1}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            ReorderableDragStartListener(
              index: index,
              enabled: enabled,
              child: const SizedBox.square(
                dimension: 44,
                child: Icon(Icons.drag_handle_rounded, size: 20),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (prompt.text.isNotEmpty)
                    Text(
                      prompt.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium,
                    )
                  else
                    Text(
                      'Attachments only',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  if (attachmentCount > 0) ...<Widget>[
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: <Widget>[
                        for (final reference in prompt.imageReferences)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(5),
                            child: Image.file(
                              File(reference),
                              width: 34,
                              height: 34,
                              fit: BoxFit.cover,
                              errorBuilder: (_, _, _) => SizedBox.square(
                                dimension: 34,
                                child: ColoredBox(
                                  color: colors.surfaceContainerHigh,
                                  child: const Icon(
                                    Icons.broken_image_outlined,
                                    size: 17,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        for (final document in prompt.documents)
                          Chip(
                            visualDensity: VisualDensity.compact,
                            avatar: const Icon(
                              Icons.description_outlined,
                              size: 16,
                            ),
                            label: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 120),
                              child: Text(
                                document.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit queued message',
              onPressed: enabled ? onEdit : null,
              icon: const Icon(Icons.edit_outlined, size: 19),
            ),
            IconButton(
              tooltip: 'Remove queued message',
              onPressed: enabled ? onRemove : null,
              icon: const Icon(Icons.close, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

class _QueuedPromptEditor extends StatefulWidget {
  const _QueuedPromptEditor({required this.prompt});

  final QueuedPrompt prompt;

  @override
  State<_QueuedPromptEditor> createState() => _QueuedPromptEditorState();
}

class _QueuedPromptEditorState extends State<_QueuedPromptEditor> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.prompt.text,
  );

  bool get _hasAttachments =>
      widget.prompt.imageReferences.isNotEmpty ||
      widget.prompt.documents.isNotEmpty;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + keyboard),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SheetHandle(),
            const SheetHeading(
              title: 'Edit queued message',
              closeLabel: 'Close queued message editor',
            ),
            TextField(
              controller: _controller,
              autofocus: true,
              minLines: 3,
              maxLines: 8,
              onChanged: (_) => setState(() {}),
              decoration: const InputDecoration(labelText: 'Message'),
            ),
            if (_hasAttachments) ...<Widget>[
              const SizedBox(height: 10),
              const Text('Attached images and documents will be kept.'),
            ],
            const SizedBox(height: 16),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      _controller.text.trim().isNotEmpty || _hasAttachments
                      ? () => Navigator.pop(context, _controller.text.trim())
                      : null,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
