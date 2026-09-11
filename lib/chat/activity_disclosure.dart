import 'package:flutter/material.dart';

import '../ui/design.dart';

enum ToolActivityState { pending, running, succeeded, failed }

@immutable
class ToolActivityView {
  const ToolActivityView({
    required this.label,
    this.detail,
    this.state = ToolActivityState.succeeded,
  });

  final String label;
  final String? detail;
  final ToolActivityState state;
}

/// A deliberately quiet, collapsed summary of model reasoning and tool use.
class ActivityDisclosure extends StatefulWidget {
  const ActivityDisclosure({
    super.key,
    this.thinking,
    this.toolCalls = const <ToolActivityView>[],
    this.isActive = false,
  });

  final String? thinking;
  final List<ToolActivityView> toolCalls;
  final bool isActive;

  @override
  State<ActivityDisclosure> createState() => _ActivityDisclosureState();
}

class _ActivityDisclosureState extends State<ActivityDisclosure> {
  bool _expanded = false;

  @override
  void didUpdateWidget(ActivityDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive && _expanded) {
      _expanded = false;
    }
  }

  void _toggle() => setState(() => _expanded = !_expanded);

  bool get _hasThinking => widget.thinking?.trim().isNotEmpty ?? false;

  bool get _hasRunningTool =>
      widget.toolCalls.any((tool) => tool.state == ToolActivityState.running);

  String get _label {
    if (widget.isActive || _hasRunningTool) return 'Working';
    if (widget.toolCalls.isNotEmpty && _hasThinking) return 'Activity';
    if (widget.toolCalls.isNotEmpty) return 'Tool activity';
    return 'Thinking';
  }

  @override
  Widget build(BuildContext context) {
    if (!_hasThinking && widget.toolCalls.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          button: true,
          expanded: _expanded,
          label: '${_expanded ? 'Collapse' : 'Expand'} $_label',
          child: TextButton(
            onPressed: _toggle,
            style: TextButton.styleFrom(
              minimumSize: const Size(44, 44),
              padding: EdgeInsets.zero,
              foregroundColor: colors.onSurfaceVariant,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const DesignIcon('thinking', size: 16),
                const SizedBox(width: 7),
                Text(_label, style: theme.textTheme.bodySmall),
                const SizedBox(width: 5),
                AnimatedRotation(
                  turns: _expanded ? .5 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: const DesignIcon('down', size: 15),
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          _ActivityDetails(
            thinking: _hasThinking ? widget.thinking!.trim() : null,
            toolCalls: widget.toolCalls,
          ),
      ],
    );
  }
}

class _ActivityDetails extends StatelessWidget {
  const _ActivityDetails({required this.thinking, required this.toolCalls});

  final String? thinking;
  final List<ToolActivityView> toolCalls;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Divider(height: 1, color: colors.outlineVariant),
          if (thinking != null) ...<Widget>[
            const SizedBox(height: 12),
            SelectableText(
              thinking!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
          for (final tool in toolCalls) ...<Widget>[
            const SizedBox(height: 12),
            _ToolActivityRow(tool: tool),
          ],
        ],
      ),
    );
  }
}

class _ToolActivityRow extends StatelessWidget {
  const _ToolActivityRow({required this.tool});

  final ToolActivityView tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final (icon, status) = switch (tool.state) {
      ToolActivityState.pending => (Icons.schedule, 'Pending'),
      ToolActivityState.running => (Icons.autorenew, 'Running'),
      ToolActivityState.succeeded => (Icons.check, 'Completed'),
      ToolActivityState.failed => (Icons.error_outline, 'Failed'),
    };

    return Semantics(
      label: '${tool.label}, $status',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 17, color: colors.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(tool.label, style: theme.textTheme.labelMedium),
                if (tool.detail?.trim().isNotEmpty ?? false) ...<Widget>[
                  const SizedBox(height: 3),
                  SelectableText(
                    tool.detail!.trim(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
