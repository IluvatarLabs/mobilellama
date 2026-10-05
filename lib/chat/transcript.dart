import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_markdown_latex/flutter_markdown_latex.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:scroll_to_index/scroll_to_index.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/document_attachment.dart';
import '../domain/source_reference.dart';
import 'sources.dart';
import '../ui/design.dart';
import 'activity_disclosure.dart';
import 'find_in_chat.dart';
import 'diagram.dart';
import 'image_viewer.dart';
import 'share_actions.dart';
import 'speech_actions.dart';

enum TranscriptRole { user, assistant, system }

final markdown.ExtensionSet _assistantMarkdownExtensions =
    markdown.ExtensionSet(
      <markdown.BlockSyntax>[
        ...markdown.ExtensionSet.gitHubFlavored.blockSyntaxes,
        LatexBlockSyntax(),
      ],
      <markdown.InlineSyntax>[
        ...markdown.ExtensionSet.gitHubFlavored.inlineSyntaxes,
        LatexInlineSyntax(),
      ],
    );

enum TranscriptStatus {
  queued,
  sending,
  streaming,
  completed,
  interrupted,
  failed,
}

/// Presentation data only. Controllers can adapt their domain messages without
/// coupling transcript rendering to storage or transport types.
@immutable
class TranscriptMessageView {
  const TranscriptMessageView({
    required this.id,
    required this.role,
    required this.content,
    this.status = TranscriptStatus.completed,
    this.canRetry = false,
    this.canEdit = false,
    this.editRemovesLaterMessages = false,
    this.canRegenerate = false,
    this.regenerateRemovesLaterMessages = false,
    this.canRestorePrevious = false,
    this.thinking,
    this.imageReferences = const <String>[],
    this.documents = const <DocumentAttachment>[],
    this.toolCalls = const <ToolActivityView>[],
    this.sources = const <SourceReference>[],
  });

  final String id;
  final TranscriptRole role;
  final String content;
  final TranscriptStatus status;
  final bool canRetry;
  final bool canEdit;
  final bool editRemovesLaterMessages;
  final bool canRegenerate;
  final bool regenerateRemovesLaterMessages;

  /// Whether this answer's response menu offers `Restore previous
  /// conversation`. Requires [ChatTranscript.onRestorePrevious].
  final bool canRestorePrevious;
  final String? thinking;
  final List<String> imageReferences;
  final List<DocumentAttachment> documents;
  final List<ToolActivityView> toolCalls;
  final List<SourceReference> sources;

  TranscriptMessageView copyWith({bool? canRestorePrevious}) =>
      TranscriptMessageView(
        id: id,
        role: role,
        content: content,
        status: status,
        canRetry: canRetry,
        canEdit: canEdit,
        editRemovesLaterMessages: editRemovesLaterMessages,
        canRegenerate: canRegenerate,
        regenerateRemovesLaterMessages: regenerateRemovesLaterMessages,
        canRestorePrevious: canRestorePrevious ?? this.canRestorePrevious,
        thinking: thinking,
        imageReferences: imageReferences,
        documents: documents,
        toolCalls: toolCalls,
        sources: sources,
      );
}

class ChatTranscript extends StatefulWidget {
  const ChatTranscript({
    super.key,
    required this.messages,
    this.onRetry,
    this.onEditAndResend,
    this.onRegenerate,
    this.onRestorePrevious,
    this.canMutate,
    this.onCopy,
    this.onAskSelection,
    this.onOpenSourceFile,
    this.answerSpeaker,
    this.scrollController,
    this.findController,
    this.findScope,
    this.emptyState,
    this.messageFooter,
    this.bottomPadding = 24,
    this.hasOlder = false,
    this.loadingOlder = false,
    this.onLoadOlder,
  });

  final List<TranscriptMessageView> messages;
  final ValueChanged<TranscriptMessageView>? onRetry;
  final Future<bool> Function(TranscriptMessageView message, String text)?
  onEditAndResend;
  final Future<bool> Function(TranscriptMessageView message)? onRegenerate;

  /// Restores the conversation saved before the revision that produced this
  /// answer. Offered only for messages with
  /// [TranscriptMessageView.canRestorePrevious]. Returns false when refused.
  final Future<bool> Function(TranscriptMessageView message)? onRestorePrevious;
  final bool Function()? canMutate;
  final ValueChanged<String>? onCopy;
  final ValueChanged<String>? onAskSelection;
  final Future<void> Function(SourceReference)? onOpenSourceFile;
  final AnswerSpeaker? answerSpeaker;
  final ScrollController? scrollController;
  final ChatFindController? findController;
  final Object? findScope;
  final Widget? emptyState;

  /// Optional content shown directly below one message, such as a request
  /// failure with its recovery actions.
  final Widget? Function(TranscriptMessageView message)? messageFooter;
  final double bottomPadding;
  final bool hasOlder;
  final bool loadingOlder;
  final Future<void> Function()? onLoadOlder;

  @override
  State<ChatTranscript> createState() => _ChatTranscriptState();
}

class _ChatTranscriptState extends State<ChatTranscript>
    with WidgetsBindingObserver {
  static const double _nearBottomThreshold = 96;

  late AutoScrollController _scrollController;
  bool _followsLatest = true;
  bool _restoringAnchor = false;
  (String, double)? _readingAnchor;
  late int _tailRevision;
  late AnswerSpeaker _answerSpeaker;
  final Map<String, GlobalKey> _findTextKeys = <String, GlobalKey>{};
  String? _speakingMessageId;
  String? _speakingText;
  int _speechSession = 0;
  bool _routeWasCurrent = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _answerSpeaker = widget.answerSpeaker ?? NativeAnswerSpeaker();
    _installScrollController(widget.scrollController);
    widget.findController?.addListener(_onFindChanged);
    _tailRevision = _revisionFor(widget.messages);
    _scheduleFindItemsSync();
    _scheduleFollow();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeWasCurrent && !isCurrent) unawaited(_stopReading());
    _routeWasCurrent = isCurrent;
  }

  @override
  void didUpdateWidget(ChatTranscript oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scrollController != widget.scrollController) {
      _removeScrollController();
      _installScrollController(widget.scrollController);
      _followsLatest = true;
      _scheduleFollow();
    }
    if (oldWidget.findController != widget.findController) {
      oldWidget.findController?.removeListener(_onFindChanged);
      widget.findController?.addListener(_onFindChanged);
      _scheduleFindItemsSync();
    }
    if (oldWidget.findScope != widget.findScope) {
      _findTextKeys.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.findScope != oldWidget.findScope) {
          widget.findController?.close();
        }
      });
    }
    if (oldWidget.answerSpeaker != widget.answerSpeaker) {
      _speechSession++;
      _speakingMessageId = null;
      _speakingText = null;
      unawaited(_answerSpeaker.stop());
      _answerSpeaker = widget.answerSpeaker ?? NativeAnswerSpeaker();
    }
    if (_speakingMessageId case final id?) {
      final stillPresent = widget.messages.any(
        (message) => message.id == id && message.content == _speakingText,
      );
      if (!stillPresent) {
        _speechSession++;
        _speakingMessageId = null;
        _speakingText = null;
        unawaited(_answerSpeaker.stop());
      }
    }
    final nextRevision = _revisionFor(widget.messages);
    if (nextRevision != _tailRevision) {
      _scheduleFindItemsSync();
      _scheduleFollow();
    }
    _tailRevision = nextRevision;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_stopReading());
    }
  }

  void _installScrollController(ScrollController? suppliedController) {
    _scrollController = AutoScrollController(axis: Axis.vertical);
    if (suppliedController != null) {
      _scrollController.parentController = suppliedController;
    }
    _scrollController.addListener(_updateFollowState);
  }

  void _removeScrollController() {
    _scrollController.removeListener(_updateFollowState);
    _scrollController.dispose();
  }

  void _updateFollowState() {
    if (_restoringAnchor) return;
    if (_scrollController.hasClients) {
      final follows =
          _scrollController.position.extentAfter <= _nearBottomThreshold;
      if (follows != _followsLatest) setState(() => _followsLatest = follows);
      if (!follows) _readingAnchor = _captureAnchor();
    }
  }

  (String, double)? _captureAnchor() {
    final viewport = context.findRenderObject();
    if (viewport is! RenderBox || !viewport.hasSize) return null;
    final top = viewport.localToGlobal(Offset.zero).dy;
    final tags = _scrollController.tagMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    for (final entry in tags) {
      if (entry.key < 0 || entry.key >= widget.messages.length) continue;
      final box = entry.value.context.findRenderObject();
      if (box is! RenderBox || !box.attached || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy - top;
      if (y + box.size.height > 0 && y < viewport.size.height) {
        return (widget.messages[entry.key].id, y);
      }
    }
    return null;
  }

  Future<void> _restoreAnchor((String, double) anchor) async {
    if (!mounted || !_scrollController.hasClients) return;
    final index = widget.messages.indexWhere(
      (message) => message.id == anchor.$1,
    );
    if (index < 0) return;
    _restoringAnchor = true;
    try {
      if (!_scrollController.tagMap.containsKey(index)) {
        await _scrollController.scrollToIndex(
          index,
          preferPosition: AutoScrollPosition.begin,
          duration: const Duration(milliseconds: 1),
        );
      }
      if (!mounted || !_scrollController.hasClients) return;
      final box = _scrollController.tagMap[index]?.context.findRenderObject();
      final viewport = context.findRenderObject();
      if (box is! RenderBox ||
          viewport is! RenderBox ||
          !box.attached ||
          !box.hasSize) {
        return;
      }
      final y =
          box.localToGlobal(Offset.zero).dy -
          viewport.localToGlobal(Offset.zero).dy;
      _scrollController.jumpTo(
        (_scrollController.offset + y - anchor.$2).clamp(
          _scrollController.position.minScrollExtent,
          _scrollController.position.maxScrollExtent,
        ),
      );
    } finally {
      _restoringAnchor = false;
      _readingAnchor = _captureAnchor();
    }
  }

  Future<void> _loadOlder() async {
    if (widget.loadingOlder || widget.onLoadOlder == null) return;
    final anchor = _captureAnchor();
    setState(() => _followsLatest = false);
    _restoringAnchor = true;
    await widget.onLoadOlder!();
    if (!mounted) return;
    await WidgetsBinding.instance.endOfFrame;
    _restoringAnchor = false;
    if (anchor != null) await _restoreAnchor(anchor);
  }

  @override
  void didChangeMetrics() {
    if (_followsLatest) {
      _scheduleFollow();
    } else if (_readingAnchor case final anchor?) {
      _restoringAnchor = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_restoreAnchor(anchor));
      });
    }
  }

  void _scheduleFindItemsSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.findController?.updateItems(
        widget.messages.map((message) => message.content),
      );
    });
  }

  void _onFindChanged() {
    if (!mounted) return;
    final find = widget.findController;
    final active = find != null && find.isOpen ? find.activeMatch : null;
    setState(() {
      if (active != null) _followsLatest = false;
    });
    if (active == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      unawaited(_revealFindMatch(active));
    });
  }

  Future<void> _revealFindMatch(ChatFindMatch match) async {
    await _scrollController.scrollToIndex(
      match.itemIndex,
      preferPosition: AutoScrollPosition.begin,
      duration: const Duration(milliseconds: 220),
    );
    if (!mounted || !_isCurrentFindMatch(match)) return;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_isCurrentFindMatch(match)) return;

    final message = widget.messages[match.itemIndex];
    final targetContext = _findTextKeys[message.id]?.currentContext;
    if (targetContext == null || !targetContext.mounted) return;
    final paragraph = targetContext.findRenderObject();
    if (paragraph is! RenderParagraph) return;
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(baseOffset: match.start, extentOffset: match.end),
    );
    if (boxes.isEmpty) return;
    var matchRect = boxes.first.toRect();
    for (final box in boxes.skip(1)) {
      matchRect = matchRect.expandToInclude(box.toRect());
    }
    final transcriptBox = context.findRenderObject();
    if (transcriptBox is! RenderBox) return;
    final globalMatch = MatrixUtils.transformRect(
      paragraph.getTransformTo(null),
      matchRect.inflate(4),
    );
    final transcriptTop = transcriptBox.localToGlobal(Offset.zero).dy;
    final targetCenter = transcriptTop + transcriptBox.size.height * .32;
    final target =
        (_scrollController.offset + globalMatch.center.dy - targetCenter)
            .clamp(
              _scrollController.position.minScrollExtent,
              _scrollController.position.maxScrollExtent,
            )
            .toDouble();
    await _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  bool _isCurrentFindMatch(ChatFindMatch expected) {
    final current = widget.findController?.activeMatch;
    return (widget.findController?.isOpen ?? false) &&
        current != null &&
        current.itemIndex == expected.itemIndex &&
        current.start == expected.start &&
        current.end == expected.end &&
        expected.itemIndex >= 0 &&
        expected.itemIndex < widget.messages.length;
  }

  int _revisionFor(List<TranscriptMessageView> messages) {
    if (messages.isEmpty) return 0;
    final tail = messages.last;
    return Object.hash(
      messages.length,
      tail.id,
      tail.content,
      tail.status,
      tail.canRetry,
      tail.thinking,
      Object.hashAll(tail.imageReferences),
      Object.hashAll(
        tail.documents.map(
          (document) =>
              Object.hash(document.id, document.name, document.reference),
        ),
      ),
      Object.hashAll(
        tail.toolCalls.map(
          (tool) => Object.hash(tool.label, tool.detail, tool.state),
        ),
      ),
    );
  }

  Future<void> _toggleReadAloud(TranscriptMessageView message) async {
    if (_speakingMessageId == message.id) {
      await _stopReading();
      return;
    }
    await _stopReading();
    if (!mounted) return;
    final session = ++_speechSession;
    setState(() {
      _speakingMessageId = message.id;
      _speakingText = message.content;
    });
    await _answerSpeaker.speak(
      message.content,
      onStarted: () {},
      onComplete: () => _finishReading(session),
      onError: (error) => _failReading(session, error),
    );
  }

  Future<void> _stopReading() async {
    if (_speakingMessageId == null) return;
    _speechSession++;
    if (mounted) {
      setState(() {
        _speakingMessageId = null;
        _speakingText = null;
      });
    }
    await _answerSpeaker.stop();
  }

  void _finishReading(int session) {
    if (!mounted || session != _speechSession) return;
    setState(() {
      _speakingMessageId = null;
      _speakingText = null;
    });
  }

  void _failReading(int session, String message) {
    if (!mounted || session != _speechSession) return;
    setState(() {
      _speakingMessageId = null;
      _speakingText = null;
    });
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  void _scheduleFollow() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_followsLatest || !_scrollController.hasClients) return;
      final target = _scrollController.position.maxScrollExtent;
      if (_scrollController.offset != target) _scrollController.jumpTo(target);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _speechSession++;
    unawaited(_answerSpeaker.stop());
    widget.findController?.removeListener(_onFindChanged);
    _removeScrollController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (widget.messages.isEmpty && widget.emptyState != null) {
      return ColoredBox(
        color: colors.surfaceContainerLowest,
        child: widget.emptyState!,
      );
    }

    return ColoredBox(
      color: colors.surfaceContainerLowest,
      child: Stack(
        children: [
          ListView.builder(
            key: const PageStorageKey<String>('transcript-list'),
            controller: _scrollController,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            padding: EdgeInsets.fromLTRB(
              Design.gutter,
              Design.gutter,
              Design.gutter,
              widget.bottomPadding,
            ),
            itemCount: widget.messages.length + (widget.hasOlder ? 1 : 0),
            findChildIndexCallback: (key) {
              if (key is! ValueKey<String>) return null;
              final index = widget.messages.indexWhere(
                (message) => message.id == key.value,
              );
              return index < 0 ? null : index + (widget.hasOlder ? 1 : 0);
            },
            itemBuilder: (context, row) {
              if (widget.hasOlder && row == 0) {
                return TextButton(
                  onPressed: widget.loadingOlder ? null : _loadOlder,
                  child: Text(
                    widget.loadingOlder
                        ? 'Loading older messages…'
                        : 'Load older messages',
                  ),
                );
              }
              final index = row - (widget.hasOlder ? 1 : 0);
              final message = widget.messages[index];
              return AutoScrollTag(
                key: ValueKey<String>(message.id),
                controller: _scrollController,
                index: index,
                child: _buildMessage(context, index),
              );
            },
          ),
          if (!_followsLatest)
            Positioned(
              bottom: 8,
              left: 0,
              right: 0,
              child: Center(
                child: RoundAction(
                  icon: 'down',
                  label: 'Jump to latest',
                  onPressed: () {
                    setState(() => _followsLatest = true);
                    _scrollController.animateTo(
                      _scrollController.position.maxScrollExtent,
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOut,
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildMessage(BuildContext context, int index) {
    final message = widget.messages[index];
    final findTextKey = _findTextKeys.putIfAbsent(
      message.id,
      () => GlobalKey(debugLabel: 'find-${message.id}'),
    );
    final footer = widget.messageFooter?.call(message);
    final body = _TranscriptMessage(
      onAskSelection: widget.onAskSelection,
      onOpenSourceFile: widget.onOpenSourceFile,
      message: message,
      messageIndex: index,
      findTextKey: findTextKey,
      findController: widget.findController,
      onRetry: widget.onRetry,
      onEditAndResend: widget.onEditAndResend,
      onRegenerate: widget.onRegenerate,
      onRestorePrevious: widget.onRestorePrevious,
      canMutate: widget.canMutate,
      onCopy: widget.onCopy,
      isSpeaking: _speakingMessageId == message.id,
      onReadAloud: _toggleReadAloud,
    );
    return Padding(
      padding: EdgeInsets.only(
        bottom: message.role == TranscriptRole.user ? 30 : 24,
      ),
      child: footer == null
          ? body
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                body,
                const SizedBox(height: Design.space2),
                footer,
              ],
            ),
    );
  }
}

class _TranscriptMessage extends StatelessWidget {
  const _TranscriptMessage({
    required this.message,
    required this.messageIndex,
    required this.findTextKey,
    required this.findController,
    required this.onRetry,
    required this.onEditAndResend,
    required this.onRegenerate,
    required this.onRestorePrevious,
    required this.canMutate,
    required this.onCopy,
    this.onAskSelection,
    this.onOpenSourceFile,
    required this.isSpeaking,
    required this.onReadAloud,
  });

  final TranscriptMessageView message;
  final int messageIndex;
  final GlobalKey findTextKey;
  final ChatFindController? findController;
  final ValueChanged<TranscriptMessageView>? onRetry;
  final Future<bool> Function(TranscriptMessageView message, String text)?
  onEditAndResend;
  final Future<bool> Function(TranscriptMessageView message)? onRegenerate;
  final Future<bool> Function(TranscriptMessageView message)? onRestorePrevious;
  final bool Function()? canMutate;
  final ValueChanged<String>? onCopy;
  final ValueChanged<String>? onAskSelection;
  final Future<void> Function(SourceReference)? onOpenSourceFile;
  final bool isSpeaking;
  final ValueChanged<TranscriptMessageView> onReadAloud;

  @override
  Widget build(BuildContext context) {
    return switch (message.role) {
      TranscriptRole.user => _UserMessage(
        message: message,
        messageIndex: messageIndex,
        findTextKey: findTextKey,
        findController: findController,
        onEditAndResend: onEditAndResend,
        canMutate: canMutate,
        onCopy: onCopy,
      ),
      TranscriptRole.assistant => _AssistantMessage(
        onAskSelection: onAskSelection,
        onOpenSourceFile: onOpenSourceFile,
        message: message,
        messageIndex: messageIndex,
        findTextKey: findTextKey,
        findController: findController,
        onRetry: onRetry,
        onRegenerate: onRegenerate,
        onRestorePrevious: onRestorePrevious,
        canMutate: canMutate,
        onCopy: onCopy,
        isSpeaking: isSpeaking,
        onReadAloud: onReadAloud,
      ),
      TranscriptRole.system => _SystemMessage(
        message: message,
        messageIndex: messageIndex,
        findTextKey: findTextKey,
        findController: findController,
      ),
    };
  }
}

enum _MessageAction { copy, edit, regenerate, share, readAloud, restore }

/// Copies [text] and confirms with an announced, non-modal message. Selection
/// and scroll position are left untouched.
void _copyText(
  BuildContext context,
  String text, {
  required String confirmation,
  ValueChanged<String>? onCopy,
}) {
  Clipboard.setData(ClipboardData(text: text));
  onCopy?.call(text);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(confirmation),
        duration: const Duration(seconds: 2),
      ),
    );
}

/// The one visible menu trigger each message carries.
class _MoreButton extends StatelessWidget {
  const _MoreButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => RoundAction(
    label: label,
    icon: 'more',
    quiet: true,
    color: Theme.of(context).colorScheme.onSurfaceVariant,
    onPressed: onPressed,
  );
}

class _UserMessage extends StatelessWidget {
  const _UserMessage({
    required this.message,
    required this.messageIndex,
    required this.findTextKey,
    required this.findController,
    required this.onEditAndResend,
    required this.canMutate,
    required this.onCopy,
  });

  final TranscriptMessageView message;
  final int messageIndex;
  final GlobalKey findTextKey;
  final ChatFindController? findController;
  final Future<bool> Function(TranscriptMessageView message, String text)?
  onEditAndResend;
  final bool Function()? canMutate;
  final ValueChanged<String>? onCopy;

  bool get _mutationAvailable => canMutate?.call() ?? true;

  bool get _canCopy => message.content.trim().isNotEmpty;

  bool get _canEdit => message.canEdit && onEditAndResend != null;

  Future<void> _edit(BuildContext context) async {
    final text = await showEditMessageSheet(context, message);
    if (text == null || !context.mounted) return;
    if (!_mutationAvailable) {
      _showMutationUnavailable(context);
      return;
    }
    final saved = await onEditAndResend!(message, text);
    if (!saved && context.mounted) _showMutationUnavailable(context);
  }

  Future<void> _showMenu(BuildContext context) async {
    final action = await showActionSheet<_MessageAction>(
      context,
      title: 'Message',
      closeLabel: 'Close message actions',
      actions: <SheetAction<_MessageAction>>[
        if (_canCopy) const SheetAction(_MessageAction.copy, 'Copy message'),
        if (_canEdit)
          SheetAction(
            _MessageAction.edit,
            'Edit and resend',
            enabled: _mutationAvailable,
          ),
      ],
    );
    if (!context.mounted) return;
    switch (action) {
      case _MessageAction.copy:
        _copyText(
          context,
          message.content,
          confirmation: 'Message copied.',
          onCopy: onCopy,
        );
      case _MessageAction.edit:
        await _edit(context);
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        return Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              if (_canCopy || _canEdit) ...<Widget>[
                _MoreButton(
                  label: 'Message actions',
                  onPressed: () => _showMenu(context),
                ),
                const SizedBox(width: Design.space1),
              ],
              Flexible(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * 0.82,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerHigh,
                      borderRadius: const BorderRadius.only(
                        topLeft: Radius.circular(Design.radiusLarge),
                        topRight: Radius.circular(Design.radiusLarge),
                        bottomLeft: Radius.circular(Design.radiusLarge),
                        bottomRight: Radius.circular(5),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: <Widget>[
                          for (
                            var index = 0;
                            index < message.imageReferences.length;
                            index++
                          ) ...<Widget>[
                            _MessageImage(
                              reference: message.imageReferences[index],
                            ),
                            if (index < message.imageReferences.length - 1)
                              const SizedBox(height: Design.space2),
                          ],
                          if (message.imageReferences.isNotEmpty &&
                              (message.documents.isNotEmpty ||
                                  message.content.isNotEmpty))
                            const SizedBox(height: 10),
                          if (message.documents.isNotEmpty) ...<Widget>[
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              alignment: WrapAlignment.end,
                              children: <Widget>[
                                for (final document in message.documents)
                                  _DocumentChip(document: document),
                              ],
                            ),
                            if (message.content.isNotEmpty)
                              const SizedBox(height: 10),
                          ],
                          if (message.content.isNotEmpty)
                            _FindableText(
                              text: message.content,
                              itemIndex: messageIndex,
                              textKey: findTextKey,
                              findController: findController,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(color: colors.onSurface),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _MessageImage extends StatelessWidget {
  const _MessageImage({required this.reference});

  final String reference;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: 'Open attached image',
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => showChatImage(context, reference),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: AspectRatio(
              aspectRatio: 11 / 9,
              child: Image.file(
                File(reference),
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => ColoredBox(
                  color: colors.surfaceContainerLow,
                  child: const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DocumentChip extends StatelessWidget {
  const _DocumentChip({required this.document});

  final DocumentAttachment document;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 44, maxWidth: 250),
    child: OutlinedButton.icon(
      onPressed: () => _showDocument(context),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      icon: const Icon(Icons.description_outlined, size: 18),
      label: Text(document.name, maxLines: 1, overflow: TextOverflow.ellipsis),
    ),
  );

  Future<void> _showDocument(BuildContext context) =>
      showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: false,
        builder: (context) => ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SheetHandle(),
                SheetHeading(
                  title: document.name,
                  closeLabel: 'Close document',
                ),
                Text(
                  document.mimeType,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Flexible(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        document.text.trim().isEmpty
                            ? 'No text preview is available for this document.'
                            : document.text,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: () => shareDocument(context, document),
                  icon: const Icon(Icons.ios_share_outlined),
                  label: const Text('Share original'),
                ),
              ],
            ),
          ),
        ),
      );
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage({
    required this.message,
    required this.messageIndex,
    required this.findTextKey,
    required this.findController,
    required this.onRetry,
    required this.onRegenerate,
    required this.onRestorePrevious,
    required this.canMutate,
    required this.onCopy,
    this.onAskSelection,
    this.onOpenSourceFile,
    required this.isSpeaking,
    required this.onReadAloud,
  });

  final TranscriptMessageView message;
  final int messageIndex;
  final GlobalKey findTextKey;
  final ChatFindController? findController;
  final ValueChanged<TranscriptMessageView>? onRetry;
  final Future<bool> Function(TranscriptMessageView message)? onRegenerate;
  final Future<bool> Function(TranscriptMessageView message)? onRestorePrevious;
  final bool Function()? canMutate;
  final ValueChanged<String>? onCopy;
  final ValueChanged<String>? onAskSelection;
  final Future<void> Function(SourceReference)? onOpenSourceFile;
  final bool isSpeaking;
  final ValueChanged<TranscriptMessageView> onReadAloud;

  bool get _mutationAvailable => canMutate?.call() ?? true;

  bool get _hasActivity =>
      (message.thinking?.trim().isNotEmpty ?? false) ||
      message.toolCalls.isNotEmpty;

  bool get _isIncomplete =>
      message.status == TranscriptStatus.interrupted ||
      message.status == TranscriptStatus.failed;

  /// Streaming, sending, and queued answers have no revision menu.
  bool get _isSettled =>
      message.status == TranscriptStatus.completed || _isIncomplete;

  bool get _hasContent => message.content.trim().isNotEmpty;

  bool get _canRetry => _isIncomplete && message.canRetry && onRetry != null;

  bool get _canRegenerate =>
      message.canRegenerate &&
      (!_isIncomplete || !message.canRetry) &&
      onRegenerate != null;

  bool get _canRestore =>
      message.canRestorePrevious && onRestorePrevious != null;

  List<SheetAction<_MessageAction>> get _menuActions =>
      <SheetAction<_MessageAction>>[
        // A completed answer keeps Copy visible; an incomplete one keeps
        // Retry visible and moves Copy into the menu.
        if (_isIncomplete && _hasContent)
          const SheetAction(_MessageAction.copy, 'Copy response'),
        if (_canRegenerate)
          SheetAction(
            _MessageAction.regenerate,
            'Regenerate',
            enabled: _mutationAvailable,
          ),
        if (_hasContent) const SheetAction(_MessageAction.share, 'Share'),
        if (_hasContent)
          SheetAction(
            _MessageAction.readAloud,
            isSpeaking ? 'Stop reading' : 'Read aloud',
          ),
        if (_canRestore)
          const SheetAction(
            _MessageAction.restore,
            'Restore previous conversation',
          ),
      ];

  Future<void> _showMenu(BuildContext context) async {
    final action = await showActionSheet<_MessageAction>(
      context,
      title: 'Response',
      closeLabel: 'Close response actions',
      actions: _menuActions,
    );
    if (!context.mounted) return;
    switch (action) {
      case _MessageAction.copy:
        _copy(context);
      case _MessageAction.regenerate:
        await _regenerate(context);
      case _MessageAction.share:
        await shareResponse(context, message.content);
      case _MessageAction.readAloud:
        onReadAloud(message);
      case _MessageAction.restore:
        // The caller reports the outcome, including a Stop-first instruction.
        await onRestorePrevious!(message);
      default:
        break;
    }
  }

  void _copy(BuildContext context) => _copyText(
    context,
    message.content,
    confirmation: 'Response copied.',
    onCopy: onCopy,
  );

  Future<void> _regenerate(BuildContext context) async {
    if (message.regenerateRemovesLaterMessages) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Regenerate this response?'),
          content: const Text(
            'This response and every message after it will be replaced. '
            'You can restore the previous conversation until you send or '
            'revise another message.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Regenerate'),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
    }
    if (!_mutationAvailable) {
      _showMutationUnavailable(context);
      return;
    }
    final regenerated = await onRegenerate!(message);
    if (!regenerated && context.mounted) _showMutationUnavailable(context);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final hasContent = _hasContent;
    final showMenu = _isSettled && _menuActions.isNotEmpty;
    final showCopy = hasContent && !_isIncomplete;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_hasActivity) ...<Widget>[
          ActivityDisclosure(
            thinking: message.thinking,
            toolCalls: message.toolCalls,
            isActive: message.status == TranscriptStatus.streaming,
          ),
          if (hasContent) const SizedBox(height: Design.space1),
        ],
        if (!hasContent &&
            !_hasActivity &&
            message.status == TranscriptStatus.streaming)
          Align(
            alignment: Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: Design.space2),
                Text(
                  'Working',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (hasContent && (findController == null || !findController!.isOpen))
          _AnswerSelection(
            content: message.content,
            enabled: message.status != TranscriptStatus.streaming,
            onAsk: onAskSelection,
            child: MarkdownBody(
              data: message.content,
              selectable: false,
              extensionSet: _assistantMarkdownExtensions,
              onTapLink: (text, href, title) => _openLink(context, href),
              sizedImageBuilder: (config) =>
                  _BlockedMarkdownImage(alt: config.alt),
              builders: <String, MarkdownElementBuilder>{
                'pre': _CodeBlockBuilder(
                  settled: message.status != TranscriptStatus.streaming,
                ),
                'latex': _SafeLatexBuilder(
                  textStyle: theme.textTheme.bodyLarge,
                ),
              },
              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                p: theme.textTheme.bodyLarge,
                blockSpacing: 16,
                blockquoteDecoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  border: Border(
                    left: BorderSide(color: colors.outline, width: 3),
                  ),
                ),
              ),
            ),
          )
        else if (hasContent)
          _FindableText(
            text: message.content,
            itemIndex: messageIndex,
            textKey: findTextKey,
            findController: findController,
            style: theme.textTheme.bodyLarge,
          ),
        if (message.sources.isNotEmpty)
          AnswerSources(sources: message.sources, onOpenFile: onOpenSourceFile),
        if (showCopy || showMenu || _isIncomplete || isSpeaking)
          Padding(
            padding: const EdgeInsets.only(top: Design.space2),
            child: Wrap(
              spacing: 2,
              runSpacing: 0,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (showCopy)
                  RoundAction(
                    label: 'Copy response',
                    icon: 'copy',
                    quiet: true,
                    color: colors.onSurfaceVariant,
                    onPressed: () => _copy(context),
                  ),
                if (isSpeaking)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(Design.target, Design.target),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Design.space2,
                      ),
                    ),
                    onPressed: () => onReadAloud(message),
                    icon: const Icon(Icons.stop_circle_outlined, size: 18),
                    label: const Text('Stop reading'),
                  ),
                if (_isIncomplete)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Design.space1,
                    ),
                    child: Text(
                      message.status == TranscriptStatus.interrupted
                          ? 'Interrupted'
                          : 'Failed',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (_canRetry)
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(48, 48),
                      padding: const EdgeInsets.symmetric(
                        horizontal: Design.space2,
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: _mutationAvailable
                        ? () => onRetry!(message)
                        : null,
                    icon: const Icon(Icons.refresh, size: 17),
                    label: const Text('Retry'),
                  ),
                if (showMenu)
                  _MoreButton(
                    label: 'Response actions',
                    onPressed: () => _showMenu(context),
                  ),
              ],
            ),
          ),
        if (_canRestore)
          _RecoveryNotice(onRestore: () => onRestorePrevious!(message)),
      ],
    );
  }

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = href == null ? null : Uri.tryParse(href);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        (scheme != 'https' && scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _showLinkError(context, 'Only safe HTTP and HTTPS links can be opened.');
      return;
    }

    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && context.mounted) {
        _showLinkError(context, 'This link could not be opened.');
      }
    } on Object {
      if (context.mounted) {
        _showLinkError(context, 'This link could not be opened.');
      }
    }
  }

  void _showLinkError(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Keep settled Markdown elements stable while a different answer streams.
class _AnswerSelection extends StatefulWidget {
  const _AnswerSelection({
    required this.content,
    required this.enabled,
    required this.child,
    this.onAsk,
  });
  final String content;
  final bool enabled;
  final Widget child;
  final ValueChanged<String>? onAsk;
  @override
  State<_AnswerSelection> createState() => _AnswerSelectionState();
}

class _AnswerSelectionState extends State<_AnswerSelection> {
  String _selected = '';
  Widget? _settledChild;
  Object? _renderKey;
  @override
  Widget build(BuildContext context) {
    final key = (
      widget.content,
      widget.enabled,
      Theme.of(context),
      MediaQuery.textScalerOf(context),
    );
    if (!widget.enabled || key != _renderKey) {
      _settledChild = widget.child;
      _renderKey = key;
    }
    return widget.enabled
        ? SelectionArea(
            onSelectionChanged: (content) =>
                _selected = content?.plainText ?? '',
            contextMenuBuilder: (context, region) =>
                AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: region.contextMenuAnchors,
                  buttonItems: [
                    ...region.contextMenuButtonItems,
                    if (widget.onAsk != null && _selected.trim().isNotEmpty)
                      ContextMenuButtonItem(
                        label: 'Ask about this',
                        onPressed: () {
                          final text = _selected;
                          region.hideToolbar();
                          widget.onAsk!(text);
                        },
                      ),
                  ],
                ),
            child: _settledChild!,
          )
        : SelectionContainer.disabled(child: widget.child);
  }
}

class _RecoveryNotice extends StatelessWidget {
  const _RecoveryNotice({required this.onRestore});
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: Design.space2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: Design.line(context)),
          borderRadius: BorderRadius.circular(Design.radiusMedium),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            Design.space1,
            0,
            Design.space3,
            Design.space2,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextButton.icon(
                style: TextButton.styleFrom(
                  minimumSize: const Size(Design.target, Design.target),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Design.space2,
                  ),
                ),
                onPressed: onRestore,
                icon: const Icon(Icons.history, size: 18),
                label: const Text('Restore previous conversation'),
              ),
              Padding(
                padding: const EdgeInsets.only(left: Design.space2),
                child: Text(
                  'Available until you send or revise another message.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _showMutationUnavailable(BuildContext context) {
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(content: Text('Wait for the current action to finish.')),
  );
}

Future<String?> showEditMessageSheet(
  BuildContext context,
  TranscriptMessageView message,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  requestFocus: true,
  showDragHandle: false,
  barrierColor: Design.ink.withValues(alpha: .70),
  builder: (context) => _EditMessageSheet(message: message),
);

class _EditMessageSheet extends StatefulWidget {
  const _EditMessageSheet({required this.message});

  final TranscriptMessageView message;

  @override
  State<_EditMessageSheet> createState() => _EditMessageSheetState();
}

class _EditMessageSheetState extends State<_EditMessageSheet> {
  late final TextEditingController _text = TextEditingController(
    text: widget.message.content,
  );
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final edited = _text.text.trim();
    final hasAttachments =
        widget.message.imageReferences.isNotEmpty ||
        widget.message.documents.isNotEmpty;
    if (edited.isEmpty && !hasAttachments) {
      setState(() => _error = 'Enter a message.');
      return;
    }
    Navigator.pop(context, edited);
  }

  @override
  Widget build(BuildContext context) {
    final warning =
        '${widget.message.editRemovesLaterMessages ? 'This replaces this message and every reply after it.' : 'This replaces this message and the replies after it.'} '
        'You can restore the previous conversation until you send or revise '
        'another message.';
    return KeyboardSafeSheet(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const SheetHandle(),
          const SheetHeading(
            title: 'Edit message',
            closeLabel: 'Close edit message',
          ),
          const SizedBox(height: 8),
          TextField(
            key: const ValueKey<String>('edit-message-field'),
            controller: _text,
            autofocus: true,
            minLines: 3,
            maxLines: 10,
            textAlignVertical: TextAlignVertical.top,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              errorText: _error,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            warning,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (widget.message.imageReferences.isNotEmpty ||
              widget.message.documents.isNotEmpty) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              'Attached images and documents stay with the edited message.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 4),
              FilledButton(
                onPressed: _submit,
                child: const Text('Save & resend'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BlockedMarkdownImage extends StatelessWidget {
  const _BlockedMarkdownImage({this.alt});

  final String? alt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final description = alt?.trim();
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.hide_image_outlined, color: colors.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              description == null || description.isEmpty
                  ? 'Remote image blocked'
                  : 'Remote image blocked · $description',
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder({required this.settled});
  final bool settled;
  String _language = '';

  @override
  void visitElementBefore(markdown.Element element) {
    _language = '';
    try {
      final children = element.children;
      if (children != null && children.isNotEmpty) {
        final child = children.first;
        final rawClass = child is markdown.Element
            ? child.attributes['class'] ?? ''
            : '';
        if (rawClass.startsWith('language-')) {
          _language = rawClass.substring('language-'.length);
        }
      }
    } on Object {
      _language = '';
    }
  }

  @override
  Widget visitText(markdown.Text text, TextStyle? preferredStyle) {
    if (settled &&
        _language.toLowerCase() == 'mermaid' &&
        AnswerDiagram.supports(text.text)) {
      return AnswerDiagram(source: text.text);
    }
    return _CodeBlock(
      code: text.text,
      language: _language,
      style: preferredStyle,
    );
  }
}

class _CodeBlock extends StatelessWidget {
  const _CodeBlock({
    required this.code,
    required this.language,
    required this.style,
  });

  final String code;
  final String language;
  final TextStyle? style;

  static final Highlight _highlighter = Highlight()
    ..registerLanguages(builtinAllLanguages);

  static const Map<String, String> _languageAliases = <String, String>{
    'c++': 'cpp',
    'cs': 'csharp',
    'html': 'xml',
    'js': 'javascript',
    'jsx': 'javascript',
    'md': 'markdown',
    'py': 'python',
    'rb': 'ruby',
    'sh': 'bash',
    'shell': 'bash',
    'ts': 'typescript',
    'tsx': 'typescript',
    'yml': 'yaml',
  };

  TextSpan _highlightedCode(BuildContext context, TextStyle base) {
    final requested = language.trim().toLowerCase();
    final resolved = _languageAliases[requested] ?? requested;
    if (resolved.isEmpty || _highlighter.getLanguage(resolved) == null) {
      return TextSpan(text: code, style: base);
    }
    try {
      final result = _highlighter.highlight(code: code, language: resolved);
      final renderer = TextSpanRenderer(
        base,
        Theme.of(context).brightness == Brightness.dark
            ? githubDarkTheme
            : githubTheme,
      );
      result.render(renderer);
      return renderer.span ?? TextSpan(text: code, style: base);
    } on Object {
      return TextSpan(text: code, style: base);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final codeStyle = (style ?? theme.textTheme.bodyMedium ?? const TextStyle())
        .copyWith(
          fontFamily: 'monospace',
          color: colors.onSurface,
          backgroundColor: Colors.transparent,
        );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    language.isEmpty ? 'Code' : language,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Copy code',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: () => Clipboard.setData(ClipboardData(text: code)),
                icon: const Icon(Icons.content_copy_outlined, size: 18),
              ),
            ],
          ),
          Divider(height: 1, color: colors.outlineVariant),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.all(12),
            child: SelectableText.rich(_highlightedCode(context, codeStyle)),
          ),
        ],
      ),
    );
  }
}

class _SafeLatexBuilder extends MarkdownElementBuilder {
  _SafeLatexBuilder({required this.textStyle});

  final TextStyle? textStyle;

  @override
  Widget visitElementAfterWithContext(
    BuildContext context,
    markdown.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final source = element.textContent;
    if (source.isEmpty) return const SizedBox.shrink();
    final display = element.attributes['MathStyle'] == 'display';
    final effectiveStyle = textStyle ?? preferredStyle ?? parentStyle;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Math.tex(
        source,
        mathStyle: display ? MathStyle.display : MathStyle.text,
        textStyle: effectiveStyle,
        settings: const TexParserSettings(strict: Strict.ignore),
        onErrorFallback: (_) => SelectableText(source, style: effectiveStyle),
      ),
    );
  }
}

class _FindableText extends StatelessWidget {
  const _FindableText({
    required this.text,
    required this.itemIndex,
    required this.findController,
    this.textKey,
    this.style,
    this.textAlign,
  });

  final String text;
  final int itemIndex;
  final ChatFindController? findController;
  final GlobalKey? textKey;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    final find = findController;
    final matches = find != null && find.isOpen
        ? find.matchesFor(itemIndex).toList(growable: false)
        : const <ChatFindMatch>[];
    if (matches.isEmpty) {
      return SelectableText(text, style: style, textAlign: textAlign);
    }

    final colors = Theme.of(context).colorScheme;
    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final match in matches) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      final active = find!.isActive(match);
      spans.add(
        TextSpan(
          text: text.substring(match.start, match.end),
          style: TextStyle(
            color: active ? colors.onPrimary : colors.onSurface,
            backgroundColor: active ? colors.primary : colors.primaryContainer,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return SelectionArea(
      child: Builder(
        builder: (context) => RichText(
          key: textKey,
          text: TextSpan(style: style, children: spans),
          textAlign: textAlign ?? TextAlign.start,
          selectionRegistrar: SelectionContainer.maybeOf(context),
          selectionColor: colors.primary.withValues(alpha: .28),
        ),
      ),
    );
  }
}

class _SystemMessage extends StatelessWidget {
  const _SystemMessage({
    required this.message,
    required this.messageIndex,
    required this.findTextKey,
    required this.findController,
  });

  final TranscriptMessageView message;
  final int messageIndex;
  final GlobalKey findTextKey;
  final ChatFindController? findController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: _FindableText(
              text: message.content,
              itemIndex: messageIndex,
              textKey: findTextKey,
              findController: findController,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
