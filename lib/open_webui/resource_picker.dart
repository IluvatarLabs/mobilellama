import 'dart:convert';

import 'package:flutter/material.dart';

import 'client.dart';
import 'resources.dart';
import 'workspace.dart';

class WebUiResourcePicker extends StatefulWidget {
  const WebUiResourcePicker({
    super.key,
    required this.workspace,
    required this.kind,
    required this.onInsert,
    this.mention = false,
  });
  final WebUiWorkspace workspace;
  final WebUiResourceKind kind;
  final ValueChanged<String> onInsert;
  final bool mention;
  @override
  State<WebUiResourcePicker> createState() => _WebUiResourcePickerState();
}

class _WebUiResourcePickerState extends State<WebUiResourcePicker> {
  final _items = <Map<String, dynamic>>[];
  int _page = 0;
  bool _loading = false, _hasMore = true;
  String _query = '';
  String? _error;
  WebUiWorkspace get w => widget.workspace;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await w.serverResources.list(widget.kind, page: _page + 1);
      if (!mounted) return;
      setState(() {
        _items.addAll(page.items);
        _page++;
        _hasMore = page.hasMore;
      });
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is WebUiException ? error.message : 'These server resources are unavailable. You can still use ordinary chat.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool _selected(Map item) => switch (widget.kind) {
    WebUiResourceKind.tools =>
      (w.resources['tool_ids'] as List? ?? []).contains(item['id']),
    WebUiResourceKind.skills =>
      (w.resources['skill_ids'] as List? ?? []).contains(item['id']),
    _ => (w.resources['files'] as List? ?? []).any(
      (value) => value is Map && value['id'] == item['id'],
    ),
  };
  Future<void> _choose(Map<String, dynamic> item) async {
    try {
      if (widget.kind == WebUiResourceKind.prompts) {
        final template = item['content'];
        if (template is! String) {
          throw const WebUiException('This prompt has no usable text.');
        }
        final resolved = await resolveServerPrompt(context, template);
        if (resolved == null || !mounted) return;
        widget.onInsert(resolved);
        Navigator.pop(context);
      } else if (widget.kind == WebUiResourceKind.skills && widget.mention) {
        final title = WebUiResources.title(
          widget.kind,
          item,
        ).replaceAll(RegExp(r'[<>|]'), ' ');
        widget.onInsert('<\$${item['id']}|$title> ');
        Navigator.pop(context);
      } else {
        await w.setResource(widget.kind, item, !_selected(item));
        if (mounted) setState(() => _error = null);
      }
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _error = error is WebUiException
              ? error.message
              : 'This selection could not be saved.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: w,
    builder: (context, _) => w.locked
        ? const Center(child: Text('Sign in again to view this account.'))
        : DraggableScrollableSheet(
            expand: false,
            initialChildSize: .75,
            builder: (context, scroll) => ListView(
              controller: scroll,
              padding: const EdgeInsets.all(20),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(switch (widget.kind) {
                        WebUiResourceKind.files => 'Server files',
                        WebUiResourceKind.knowledge => 'Knowledge',
                        WebUiResourceKind.prompts => 'Prompts',
                        WebUiResourceKind.skills => 'Skills',
                        WebUiResourceKind.tools => 'Tools',
                      }, style: Theme.of(context).textTheme.titleLarge),
                    ),
                    IconButton(
                      tooltip: 'Close resource picker',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                if (widget.kind == WebUiResourceKind.tools)
                  const Text(
                    'Selected workspace tools run on your server. Its built-in tools and model defaults may also run; this list does not disable them.',
                  ),
                if (widget.kind == WebUiResourceKind.skills)
                  Text(
                    widget.mention
                        ? 'Insert a skill invocation into your message. Review it before sending.'
                        : 'Select skills for this chat. Model-attached defaults are managed by your server.',
                  ),
                if (widget.kind == WebUiResourceKind.prompts)
                  const Text(
                    'Insert a prompt into your draft. Your chat instructions and attachments stay as they are.',
                  ),
                const SizedBox(height: 12),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Filter loaded resources',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) =>
                      setState(() => _query = value.toLowerCase()),
                ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(_error!),
                  ),
                for (final item in _items.where(
                  (item) => WebUiResources.title(
                    widget.kind,
                    item,
                  ).toLowerCase().contains(_query),
                ))
                  Builder(
                    builder: (context) {
                      final unavailable =
                          item['is_active'] == false ||
                          (item['id'] as String? ?? '').startsWith(
                            'direct_server:',
                          );
                      final selectable =
                          widget.kind != WebUiResourceKind.prompts &&
                          !widget.mention;
                      final description = unavailable
                          ? 'Unavailable on this device or disabled on the server'
                          : item['description'] as String? ??
                                (item['meta'] as Map?)?['description']
                                    as String?;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        enabled: !unavailable && !w.locked,
                        title: Text(WebUiResources.title(widget.kind, item)),
                        subtitle: description == null
                            ? null
                            : Text(
                                description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                        leading: selectable
                            ? Checkbox(
                                value: _selected(item),
                                onChanged: unavailable || w.locked
                                    ? null
                                    : (_) => _choose(item),
                              )
                            : null,
                        onTap: unavailable || w.locked
                            ? null
                            : () => _choose(item),
                        trailing:
                            widget.kind == WebUiResourceKind.skills &&
                                !widget.mention
                            ? IconButton(
                                tooltip: 'Insert skill mention',
                                onPressed: unavailable
                                    ? null
                                    : () {
                                        final title = WebUiResources.title(
                                          widget.kind,
                                          item,
                                        ).replaceAll(RegExp(r'[<>|]'), ' ');
                                        widget.onInsert(
                                          '<\$${item['id']}|$title> ',
                                        );
                                        Navigator.pop(context);
                                      },
                                icon: const Icon(Icons.alternate_email),
                              )
                            : null,
                      );
                    },
                  ),
                if (_loading)
                  const Center(child: CircularProgressIndicator())
                else if (_items.isEmpty && _error == null)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No accessible resources are available.'),
                  ),
                if (!_loading && (_hasMore || _error != null))
                  TextButton(
                    onPressed: _load,
                    child: Text(_error == null ? 'Load more' : 'Retry'),
                  ),
              ],
            ),
          ),
  );
}

/// Uses the server's {{name}} and {{name | definition}} placeholder syntax.
/// Values are inserted as literal text, never evaluated or sent automatically.
Future<String?> resolveServerPrompt(
  BuildContext context,
  String template,
) async {
  final pattern = RegExp(r'\{\{\s*([^|}\s]+)\s*(?:\|\s*([^}]+))?\s*\}\}');
  final variables = <String, Map<String, dynamic>>{};
  for (final match in pattern.allMatches(template)) {
    final name = match.group(1)!;
    final definition = match.group(2);
    if (definition == null) {
      variables.putIfAbsent(name, () => {'type': 'text'});
      continue;
    }
    final parts = _promptProperties(definition.trim(), ':');
    variables[name] = {'type': parts.first.replaceFirst(RegExp(r'^type='), '')};
    for (final part in parts.skip(1)) {
      final pair = _promptProperties(part, '=');
      Object? value = true;
      if (pair.length > 1) {
        final raw = pair.skip(1).join('=');
        try {
          value = jsonDecode(raw);
        } on FormatException {
          value = raw;
        }
      }
      variables[name]![pair.first] = value;
    }
  }
  if (variables.isEmpty) return template;
  final fields = {
    for (final entry in variables.entries)
      entry.key: TextEditingController(
        text: (entry.value['default'] ?? '').toString(),
      ),
  };
  bool missingRequired() => fields.entries.any(
    (entry) =>
        (variables[entry.key]!['required'] == true ||
            variables[entry.key]!['required'] == 'true') &&
        entry.value.text.trim().isEmpty,
  );
  final route = DialogRoute<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('Fill in this prompt'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in fields.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextField(
                    controller: entry.value,
                    decoration: InputDecoration(
                      labelText:
                          '${entry.key}${variables[entry.key]!['required'] == true || variables[entry.key]!['required'] == 'true' ? ' *' : ''}',
                      hintText: variables[entry.key]!['placeholder']
                          ?.toString(),
                      helperText: variables[entry.key]!['options'] == null
                          ? variables[entry.key]!['type']?.toString()
                          : 'Options: ${variables[entry.key]!['options']}',
                    ),
                    keyboardType: variables[entry.key]!['type'] == 'number'
                        ? TextInputType.number
                        : TextInputType.text,
                    onChanged: (_) => update(() {}),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: missingRequired()
                ? null
                : () => Navigator.pop(context, true),
            child: const Text('Insert prompt'),
          ),
        ],
      ),
    ),
  );
  final selected = await Navigator.of(context, rootNavigator: true).push(route);
  final resolved = selected == true
      ? template.replaceAllMapped(
          pattern,
          (match) => fields[match.group(1)]!.text,
        )
      : null;
  // A pop result arrives before the closing transition removes TextFields.
  await route.completed;
  for (final field in fields.values) {
    field.dispose();
  }
  return resolved;
}

List<String> _promptProperties(String value, String delimiter) {
  final result = <String>[];
  var start = 0, depth = 0;
  var quoted = false, escaped = false;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (escaped) {
      escaped = false;
      continue;
    }
    if (char == r'\') {
      escaped = true;
      continue;
    }
    if (char == '"') {
      quoted = !quoted;
      continue;
    }
    if (quoted) continue;
    if (char == '[' || char == '{') depth++;
    if (char == ']' || char == '}') depth--;
    if (char == delimiter && depth == 0) {
      result.add(value.substring(start, index).trim());
      start = index + 1;
    }
  }
  result.add(value.substring(start).trim());
  return result;
}

/// Exact v0.11.4 ask_user answer shape, shared by live event acknowledgments
/// and persisted tool-call resolution. Each question has a server-supplied ID.
Future<Map<String, dynamic>?> answerServerQuestions(
  BuildContext context,
  Object? raw, {
  bool allowOther = true,
}) async {
  final questions = (raw is List ? raw : const []).whereType<Map>().toList();
  if (questions.isEmpty || questions.any((q) => q['id'] is! String)) {
    return null;
  }
  final answers = <String, dynamic>{};
  final fields = {
    for (final q in questions) q['id'] as String: TextEditingController(),
  };
  final route = DialogRoute<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: const Text('The server needs your input'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final q in questions) ...[
                Text(
                  q['question'] as String? ??
                      q['header'] as String? ??
                      'Question',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                for (final (index, option)
                    in (q['options'] as List? ?? []).indexed)
                  if (option is Map)
                    RadioListTile<int>(
                      value: index,
                      groupValue:
                          (answers[q['id']] as Map?)?['option_index'] as int?,
                      title: Text(
                        option['label'] as String? ?? 'Option ${index + 1}',
                      ),
                      subtitle: option['description'] is String
                          ? Text(option['description'] as String)
                          : null,
                      onChanged: (_) => update(
                        () => answers[q['id'] as String] = {
                          'type': 'option',
                          'option_index': index,
                          'label': option['label'] ?? '',
                          'description': option['description'] ?? '',
                        },
                      ),
                    ),
                if (q['allow_other'] != false && allowOther)
                  TextField(
                    controller: fields[q['id']],
                    decoration: const InputDecoration(labelText: 'Your answer'),
                    onChanged: (text) => update(() {
                      if (text.trim().isEmpty) {
                        answers.remove(q['id']);
                      } else {
                        answers[q['id'] as String] = {
                          'type': 'other',
                          'text': text.trim(),
                        };
                      }
                    }),
                  ),
                const SizedBox(height: 20),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: answers.length == questions.length
                ? () => Navigator.pop(context, true)
                : null,
            child: const Text('Submit answers'),
          ),
        ],
      ),
    ),
  );
  final accepted = await Navigator.of(context, rootNavigator: true).push(route);
  await route.completed;
  for (final field in fields.values) {
    field.dispose();
  }
  return accepted == true
      ? {'status': 'answered', 'answers': jsonDecode(jsonEncode(answers))}
      : null;
}
