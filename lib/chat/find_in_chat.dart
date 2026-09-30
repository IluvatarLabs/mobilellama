import 'package:flutter/material.dart';

@immutable
class ChatFindMatch {
  const ChatFindMatch({
    required this.itemIndex,
    required this.start,
    required this.end,
  });

  final int itemIndex;
  final int start;
  final int end;
}

class ChatFindController extends ChangeNotifier {
  bool _open = false;
  String _query = '';
  List<String> _items = const <String>[];
  List<ChatFindMatch> _matches = const <ChatFindMatch>[];
  int _activeIndex = 0;

  bool get isOpen => _open;
  String get query => _query;
  int get matchCount => _matches.length;
  int get activeOrdinal => _matches.isEmpty ? 0 : _activeIndex + 1;
  ChatFindMatch? get activeMatch =>
      _matches.isEmpty ? null : _matches[_activeIndex];

  Iterable<ChatFindMatch> matchesFor(int itemIndex) =>
      _matches.where((match) => match.itemIndex == itemIndex);

  bool isActive(ChatFindMatch match) => identical(activeMatch, match);

  void open() {
    if (_open) return;
    _open = true;
    notifyListeners();
  }

  void close() {
    if (!_open) return;
    _open = false;
    notifyListeners();
  }

  void setQuery(String value) {
    if (_query == value) return;
    _query = value;
    _activeIndex = 0;
    _rebuildMatches();
    notifyListeners();
  }

  void updateItems(Iterable<String> values) {
    final next = List<String>.unmodifiable(values);
    if (_sameItems(_items, next)) return;
    _items = next;
    _rebuildMatches();
    notifyListeners();
  }

  void next() {
    if (_matches.isEmpty) return;
    _activeIndex = (_activeIndex + 1) % _matches.length;
    notifyListeners();
  }

  void previous() {
    if (_matches.isEmpty) return;
    _activeIndex = (_activeIndex - 1 + _matches.length) % _matches.length;
    notifyListeners();
  }

  void _rebuildMatches() {
    final needle = _query.trim().toLowerCase();
    final matches = <ChatFindMatch>[];
    if (needle.isNotEmpty) {
      for (var itemIndex = 0; itemIndex < _items.length; itemIndex++) {
        final haystack = _items[itemIndex].toLowerCase();
        var cursor = 0;
        while (cursor <= haystack.length - needle.length) {
          final start = haystack.indexOf(needle, cursor);
          if (start < 0) break;
          matches.add(
            ChatFindMatch(
              itemIndex: itemIndex,
              start: start,
              end: start + needle.length,
            ),
          );
          cursor = start + needle.length;
        }
      }
    }
    _matches = List.unmodifiable(matches);
    _activeIndex = matches.isEmpty
        ? 0
        : _activeIndex.clamp(0, matches.length - 1);
  }

  bool _sameItems(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }
}

class ChatFindBar extends StatefulWidget {
  const ChatFindBar({super.key, required this.controller});

  final ChatFindController controller;

  @override
  State<ChatFindBar> createState() => _ChatFindBarState();
}

class _ChatFindBarState extends State<ChatFindBar> {
  late final TextEditingController _query = TextEditingController(
    text: widget.controller.query,
  );

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(ChatFindBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      if (_query.text != widget.controller.query) {
        _query.text = widget.controller.query;
      }
    }
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    _query.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
          child: Row(
            children: <Widget>[
              const Icon(Icons.search, size: 20),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  controller: _query,
                  autofocus: true,
                  textInputAction: TextInputAction.search,
                  onChanged: widget.controller.setQuery,
                  onSubmitted: (_) => widget.controller.next(),
                  decoration: const InputDecoration(
                    hintText: 'Find in chat',
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              Semantics(
                liveRegion: true,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 44),
                  child: Text(
                    widget.controller.query.trim().isEmpty
                        ? ''
                        : '${widget.controller.activeOrdinal}/${widget.controller.matchCount}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Previous match',
                onPressed: widget.controller.matchCount == 0
                    ? null
                    : widget.controller.previous,
                icon: const Icon(Icons.keyboard_arrow_up),
              ),
              IconButton(
                tooltip: 'Next match',
                onPressed: widget.controller.matchCount == 0
                    ? null
                    : widget.controller.next,
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
              IconButton(
                tooltip: 'Close find',
                onPressed: widget.controller.close,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
