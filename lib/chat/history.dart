import 'dart:async';

import 'package:flutter/material.dart';
import 'package:markdown/markdown.dart' as markdown;

import '../data/conversation_store.dart';
import '../domain/conversation.dart';
import '../ui/design.dart';
import 'chat_actions.dart';
import 'chat_controller.dart';

String chatDateGroup(DateTime value) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final local = value.toLocal();
  if (!local.isBefore(today)) return 'Today';
  if (!local.isBefore(today.subtract(const Duration(days: 7)))) {
    return 'Previous 7 days';
  }
  return 'Older';
}

String chatServerName(ChatController controller, Conversation chat) {
  for (final profile in controller.profiles) {
    if (profile.id == chat.serverProfileId) return profile.name;
  }
  return 'Unavailable server';
}

class ChatHistoryRow extends StatelessWidget {
  const ChatHistoryRow({
    super.key,
    required this.chat,
    required this.controller,
    required this.onTap,
  });
  final Conversation chat;
  final ChatController controller;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final running = controller.isConversationRunning(chat.id);
    final colors = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      minTileHeight: 48,
      selected: controller.conversation?.id == chat.id,
      selectedColor: colors.onSurface,
      selectedTileColor: colors.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      title: Text(
        chat.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 16),
      ),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 72),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (running) ...<Widget>[
              Semantics(
                label: 'Response running',
                child: const SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
              const SizedBox(width: 5),
            ],
            Flexible(
              child: Text(
                chatServerName(controller, chat),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ),
          ],
        ),
      ),
      onTap: onTap,
      onLongPress: () => showChatActions(context, controller, chat),
    );
  }
}

class ChatHistoryPage extends StatefulWidget {
  const ChatHistoryPage({
    super.key,
    required this.controller,
    this.archived = false,
  });
  final ChatController controller;
  final bool archived;
  @override
  State<ChatHistoryPage> createState() => _ChatHistoryPageState();
}

class _ChatHistoryPageState extends State<ChatHistoryPage> {
  final _query = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  List<ConversationSearchResult> _results = const [];
  bool _loading = false;
  String? _error;
  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _changed(String value) {
    _debounce?.cancel();
    _generation++;
    if (value.trim().isEmpty) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
      });
    } else {
      _debounce = Timer(const Duration(milliseconds: 200), _search);
    }
  }

  Future<void> _search() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await widget.controller.searchConversations(_query.text);
      if (mounted && generation == _generation) {
        setState(() => _results = results);
      }
    } on Object {
      if (mounted && generation == _generation) {
        setState(() => _error = 'Search could not be completed. Try again.');
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _open(Conversation chat) async {
    await widget.controller.openConversation(chat.id);
    if (!mounted) return;
    if (widget.controller.conversation?.id == chat.id) {
      Navigator.pop(context, true);
    } else {
      showChatError(context, widget.controller);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Design.panel(context),
    appBar: widget.archived
        ? AppBar(
            title: const Text('Archived chats'),
            backgroundColor: Design.panel(context),
          )
        : null,
    body: SafeArea(
      child: Column(
        children: [
          if (!widget.archived)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      autofocus: true,
                      textInputAction: TextInputAction.search,
                      onChanged: _changed,
                      onSubmitted: (_) {
                        _debounce?.cancel();
                        _search();
                      },
                      decoration: InputDecoration(
                        hintText: 'Search chats',
                        fillColor: Design.search(context),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 13,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Design.line(context, .16),
                          ),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(
                            color: Design.line(context, .16),
                          ),
                        ),
                        prefixIcon: const Padding(
                          padding: EdgeInsets.all(13),
                          child: DesignIcon('search', size: 20),
                        ),
                        suffixIcon: _query.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _query.clear();
                                  _changed('');
                                },
                                icon: const DesignIcon('close', size: 20),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.onSurface,
                      minimumSize: const Size(62, 44),
                      padding: EdgeInsets.zero,
                      textStyle: const TextStyle(fontSize: 16),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ],
              ),
            ),
          if (_loading) const LinearProgressIndicator(),
          if (_error != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
          Expanded(
            child: widget.archived
                ? AnimatedBuilder(
                    animation: widget.controller,
                    builder: (context, _) {
                      final chats = widget.controller.archivedHistory;
                      return chats.isEmpty
                          ? const Center(child: Text('No archived chats.'))
                          : ListView.builder(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              itemCount: chats.length,
                              itemBuilder: (context, index) => ChatHistoryRow(
                                chat: chats[index],
                                controller: widget.controller,
                                onTap: () => _open(chats[index]),
                              ),
                            );
                    },
                  )
                : _results.isEmpty
                ? Center(
                    child: Text(
                      _query.text.trim().isEmpty
                          ? 'Search your saved conversations.'
                          : _loading
                          ? ''
                          : 'No chats found.',
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    itemCount: _results.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: Design.line(context, .12)),
                    itemBuilder: (context, index) {
                      final result = _results[index];
                      final chat = result.conversation;
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 19,
                          horizontal: 2,
                        ),
                        minVerticalPadding: 0,
                        title: _MatchedText(
                          chat.title,
                          _query.text,
                          title: true,
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (result.excerpt != null &&
                                !chat.title.toLowerCase().contains(
                                  _query.text.trim().toLowerCase(),
                                ))
                              _MatchedText(
                                markdown.Document()
                                    .parseLines(result.excerpt!.split('\n'))
                                    .map((node) => node.textContent)
                                    .join(' '),
                                _query.text,
                              ),
                            const SizedBox(height: 4),
                            Text(
                              [
                                chatServerName(widget.controller, chat),
                                chatDateGroup(chat.updatedAt),
                                if (chat.isArchived) 'Archived',
                              ].join(' · '),
                              style: const TextStyle(fontSize: 14),
                            ),
                          ],
                        ),
                        onTap: () => _open(chat),
                        onLongPress: () async {
                          await showChatActions(
                            context,
                            widget.controller,
                            chat,
                          );
                          if (mounted) await _search();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    ),
  );
}

class _MatchedText extends StatelessWidget {
  const _MatchedText(this.text, this.query, {this.title = false});
  final String text;
  final String query;
  final bool title;
  @override
  Widget build(BuildContext context) {
    final term = query.trim();
    final spans = <TextSpan>[];
    var cursor = 0;
    while (term.isNotEmpty) {
      final next = text.toLowerCase().indexOf(term.toLowerCase(), cursor);
      if (next < 0) break;
      spans.add(TextSpan(text: text.substring(cursor, next)));
      spans.add(
        TextSpan(
          text: text.substring(next, next + term.length),
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
      );
      cursor = next + term.length;
    }
    spans.add(TextSpan(text: text.substring(cursor)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: title ? 2 : 3,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: title ? 17 : 14,
        fontWeight: title ? FontWeight.w600 : FontWeight.normal,
        color: title ? null : Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    );
  }
}
