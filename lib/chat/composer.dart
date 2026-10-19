import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

import '../ui/design.dart';
import 'speech_actions.dart';

/// A bottom composer with one expanding text field and explicit media/action
/// controls. Transport state remains owned by the caller.
///
/// Local work and network submission are separate inputs:
/// * [editable] governs text entry, dictation, and local attachment picking.
///   When false (a brief local mutation), the field becomes read-only so focus,
///   selection, and copying are preserved.
/// * [canSubmit] governs Send/Queue. When false, [submitUnavailableReason] is
///   shown under a non-empty draft so the user knows why sending is disabled.
///
/// The field grows until it reaches the height its parent allows, then scrolls.
/// Give the composer bounded height (for example with [Flexible]) to cap it.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.onSend,
    required this.onStop,
    this.onPickImage,
    this.onTakePhoto,
    this.onPickDocument,
    this.onPasteImage,
    this.imagesEnabled = true,
    this.dictationEngine,
    this.controller,
    this.focusNode,
    this.isStreaming = false,
    this.isQueueing = false,
    this.editable = true,
    this.canSubmit = true,
    this.submitUnavailableReason,
    this.hintText = 'Message',
    this.draftScopeRevision = 0,
    this.draftText = '',
    this.onDraftChanged,
    this.hasAttachments = false,
    this.compact = false,
  });

  final Future<bool> Function(String) onSend;
  final VoidCallback onStop;
  final VoidCallback? onPickImage;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onPickDocument;
  final Future<void> Function(List<int> bytes)? onPasteImage;
  final bool imagesEnabled;
  final DictationEngine? dictationEngine;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final bool isStreaming;
  final bool isQueueing;
  final bool editable;
  final bool canSubmit;
  final String? submitUnavailableReason;
  final String hintText;
  final int draftScopeRevision;
  final String draftText;
  final ValueChanged<String>? onDraftChanged;
  final bool hasAttachments;

  /// Tighter vertical padding for short viewports (landscape, keyboard).
  final bool compact;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer>
    with WidgetsBindingObserver {
  static const int _maxMessageBytes = 64 * 1024;

  late TextEditingController _controller;
  late bool _ownsController;
  late final DictationEngine _dictation;
  bool _speechUpdate = false;
  bool _listening = false;
  bool _startingDictation = false;
  bool _speechErrorReported = false;
  int _manualEditRevision = 0;
  int _dictationSession = 0;
  late int _dictationManualRevision;
  late int _dictationScopeRevision;
  TextEditingValue? _dictationBase;
  bool _routeWasCurrent = true;

  bool get _hasContent =>
      _controller.text.trim().isNotEmpty || widget.hasAttachments;

  bool get _canSend => widget.editable && widget.canSubmit && _hasContent;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _dictation = widget.dictationEngine ?? NativeDictationEngine();
    _installController(widget.controller);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final isCurrent = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeWasCurrent && !isCurrent) unawaited(_cancelDictation());
    _routeWasCurrent = isCurrent;
  }

  @override
  void didUpdateWidget(ChatComposer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _removeController();
      _installController(widget.controller);
    }
    if (oldWidget.draftScopeRevision != widget.draftScopeRevision) {
      unawaited(_cancelDictation());
      _setControllerValue(
        TextEditingValue(
          text: widget.draftText,
          selection: TextSelection.collapsed(offset: widget.draftText.length),
        ),
      );
    }
    if ((oldWidget.editable && !widget.editable) ||
        (!oldWidget.isStreaming && widget.isStreaming)) {
      unawaited(_cancelDictation());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      unawaited(_cancelDictation());
    }
  }

  void _installController(TextEditingController? suppliedController) {
    _ownsController = suppliedController == null;
    _controller =
        suppliedController ?? TextEditingController(text: widget.draftText);
    _controller.addListener(_onTextChanged);
  }

  void _removeController() {
    _controller.removeListener(_onTextChanged);
    if (_ownsController) _controller.dispose();
  }

  void _onTextChanged() {
    if (!_speechUpdate) {
      _manualEditRevision++;
      if (_listening || _startingDictation) {
        unawaited(_cancelDictation());
      }
    }
    widget.onDraftChanged?.call(_controller.text);
    if (mounted) setState(() {});
  }

  void _setControllerValue(TextEditingValue value) {
    _speechUpdate = true;
    _controller.value = value;
    _speechUpdate = false;
  }

  Future<void> _toggleDictation() async {
    if (_listening || _startingDictation) {
      await _cancelDictation();
      return;
    }
    if (!widget.editable || widget.isStreaming) return;

    final session = ++_dictationSession;
    _dictationBase = _controller.value;
    _dictationManualRevision = _manualEditRevision;
    _dictationScopeRevision = widget.draftScopeRevision;
    _speechErrorReported = false;
    setState(() => _startingDictation = true);
    final started = await _dictation.start(
      onResult: (words, isFinal) =>
          _handleDictationResult(session, words, isFinal),
      onStopped: () => _handleDictationStopped(session),
      onError: (message) => _handleDictationError(session, message),
    );
    if (!mounted || session != _dictationSession) {
      if (started) await _dictation.cancel();
      return;
    }
    if (!started) {
      setState(() => _startingDictation = false);
      if (!_speechErrorReported) {
        _showSpeechError('Dictation is unavailable on this device.');
      }
      return;
    }
    setState(() {
      _startingDictation = false;
      _listening = true;
    });
  }

  void _handleDictationResult(int session, String words, bool isFinal) {
    if (!mounted ||
        session != _dictationSession ||
        (!_listening && !_startingDictation) ||
        _dictationScopeRevision != widget.draftScopeRevision ||
        _dictationManualRevision != _manualEditRevision) {
      return;
    }
    final base = _dictationBase;
    if (base == null) return;
    final recognized = words.trim();
    final selection = base.selection.isValid
        ? base.selection
        : TextSelection.collapsed(offset: base.text.length);
    final start = selection.start.clamp(0, base.text.length).toInt();
    final end = selection.end.clamp(start, base.text.length).toInt();
    final before = base.text.substring(0, start);
    final after = base.text.substring(end);
    var inserted = recognized;
    if (inserted.isNotEmpty &&
        before.isNotEmpty &&
        !RegExp(r'\s$').hasMatch(before)) {
      inserted = ' $inserted';
    }
    if (inserted.isNotEmpty &&
        after.isNotEmpty &&
        !RegExp(r'^\s').hasMatch(after)) {
      inserted = '$inserted ';
    }
    final next = '$before$inserted$after';
    _setControllerValue(
      TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(
          offset: before.length + inserted.length,
        ),
      ),
    );
    if (isFinal) _handleDictationStopped(session);
  }

  void _handleDictationStopped(int session) {
    if (!mounted || session != _dictationSession) return;
    _dictationSession++;
    setState(() {
      _startingDictation = false;
      _listening = false;
    });
  }

  void _handleDictationError(int session, String message) {
    if (!mounted || session != _dictationSession) return;
    _dictationSession++;
    _speechErrorReported = true;
    setState(() {
      _startingDictation = false;
      _listening = false;
    });
    _showSpeechError(message);
  }

  void _showSpeechError(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _cancelDictation() async {
    if (!_listening && !_startingDictation) return;
    _dictationSession++;
    if (mounted) {
      setState(() {
        _listening = false;
        _startingDictation = false;
      });
    }
    await _dictation.cancel();
  }

  bool get _hasAttachmentActions =>
      widget.onPickImage != null ||
      widget.onTakePhoto != null ||
      widget.onPickDocument != null;

  bool get _dictating => _listening || _startingDictation;

  bool get _canDictate => widget.editable && !widget.isStreaming;

  /// [includeDictation] folds the dictation control into this sheet when the
  /// composer is too narrow for a separate button.
  Future<void> _showAttachmentSheet({bool includeDictation = false}) async {
    FocusManager.instance.primaryFocus?.unfocus();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                ListTile(
                  minTileHeight: 56,
                  leading: const Icon(Icons.photo_library_outlined),
                  title: const Text('Photo library'),
                  subtitle: widget.imagesEnabled
                      ? null
                      : const Text('Choose an image-capable model first.'),
                  enabled: widget.imagesEnabled && widget.onPickImage != null,
                  onTap: widget.imagesEnabled && widget.onPickImage != null
                      ? () {
                          Navigator.pop(context);
                          widget.onPickImage!();
                        }
                      : null,
                ),
                ListTile(
                  minTileHeight: 56,
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: const Text('Camera'),
                  subtitle: widget.imagesEnabled
                      ? null
                      : const Text('Choose an image-capable model first.'),
                  enabled: widget.imagesEnabled && widget.onTakePhoto != null,
                  onTap: widget.imagesEnabled && widget.onTakePhoto != null
                      ? () {
                          Navigator.pop(context);
                          widget.onTakePhoto!();
                        }
                      : null,
                ),
                ListTile(
                  minTileHeight: 56,
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('Document'),
                  subtitle: const Text('PDF, TXT, or Markdown'),
                  enabled: widget.onPickDocument != null,
                  onTap: widget.onPickDocument == null
                      ? null
                      : () {
                          Navigator.pop(context);
                          widget.onPickDocument!();
                        },
                ),
                if (includeDictation)
                  ListTile(
                    minTileHeight: 56,
                    leading: const Icon(Icons.mic_none_outlined),
                    title: const Text('Dictate message'),
                    enabled: _canDictate,
                    onTap: _canDictate
                        ? () {
                            Navigator.pop(context);
                            unawaited(_toggleDictation());
                          }
                        : null,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _send() async {
    await _cancelDictation();
    if (!mounted) return;
    final text = _controller.text.trim();
    if (!_canSend) return;
    if (utf8.encode(text).length > _maxMessageBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('A message can be at most 64 KB.')),
      );
      return;
    }
    final draft = _controller.value;
    final draftScopeRevision = widget.draftScopeRevision;
    _controller.clear();
    var accepted = false;
    try {
      accepted = await widget.onSend(text);
    } finally {
      if (!accepted &&
          mounted &&
          _controller.text.isEmpty &&
          widget.draftScopeRevision == draftScopeRevision) {
        final offset = draft.selection.extentOffset
            .clamp(0, draft.text.length)
            .toInt();
        _controller.value = TextEditingValue(
          text: draft.text,
          selection: TextSelection.collapsed(offset: offset),
        );
      }
    }
  }

  Future<void> _paste() async {
    final scope = widget.draftScopeRevision;
    final before = _controller.value;
    try {
      if (defaultTargetPlatform == TargetPlatform.iOS &&
          widget.onPasteImage != null) {
        final bytes = await const MethodChannel('app.mobollama/intake')
            .invokeMethod<Uint8List>('pasteImage');
        if (!mounted || scope != widget.draftScopeRevision) return;
        if (bytes != null) {
          await widget.onPasteImage!(bytes);
          return;
        }
      }
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted ||
          scope != widget.draftScopeRevision ||
          before != _controller.value ||
          data?.text == null) {
        return;
      }
      final selection = before.selection.isValid
          ? before.selection
          : TextSelection.collapsed(offset: before.text.length);
      final next = before.text.replaceRange(
        selection.start,
        selection.end,
        data!.text!,
      );
      if (utf8.encode(next).length > _maxMessageBytes) {
        throw const FormatException('A message can be at most 64 KB.');
      }
      _controller.value = TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(
          offset: selection.start + data.text!.length,
        ),
      );
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not paste: $error')));
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dictationSession++;
    unawaited(_dictation.cancel());
    _removeController();
    super.dispose();
  }

  /// Width below which attachment and dictation share one menu button.
  static const double _narrowWidth = 330;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final controlColor = widget.editable
        ? colors.onSurfaceVariant
        : colors.onSurfaceVariant.withValues(alpha: 0.4);
    final disabledColor = colors.onSurfaceVariant.withValues(alpha: 0.35);
    final reason = widget.submitUnavailableReason;
    final showReason =
        !widget.canSubmit && reason != null && _hasContent && !_dictating;

    return Material(
      color: colors.surfaceContainerLowest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            Design.gutter,
            widget.compact ? Design.space1 : Design.space2,
            Design.gutter,
            widget.compact ? Design.space1 : Design.space3,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Design.composer(context),
              border: Border.all(color: Design.line(context)),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                Design.space2,
                widget.compact ? 2 : 6,
                7,
                widget.compact ? 2 : 6,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final narrow = constraints.maxWidth < _narrowWidth;
                  // Callers normally bound the composer. Without a bound, cap
                  // the editor at half the screen so it still scrolls.
                  final maxHeight = constraints.hasBoundedHeight
                      ? constraints.maxHeight
                      : MediaQuery.sizeOf(context).height * .5;
                  return ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxHeight),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Flexible(
                          child: _buildRow(
                            theme,
                            narrow: narrow,
                            controlColor: controlColor,
                            disabledColor: disabledColor,
                          ),
                        ),
                        if (_dictating)
                          _Caption(
                            text: _startingDictation
                                ? 'Starting dictation…'
                                : 'Listening…',
                            color: colors.error,
                            liveRegion: true,
                          )
                        else if (showReason)
                          _Caption(
                            text: reason,
                            color: colors.onSurfaceVariant,
                          ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRow(
    ThemeData theme, {
    required bool narrow,
    required Color controlColor,
    required Color disabledColor,
  }) {
    final colors = theme.colorScheme;
    final showAdd = _hasAttachmentActions || narrow;
    // Dictation keeps its own button unless the composer is narrow; then it
    // lives in the + menu, except while active so it can always be stopped.
    final showMic = !narrow || _dictating;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        if (showAdd)
          IconButton(
            tooltip: narrow ? 'Add attachment or dictate' : 'Add attachment',
            constraints: const BoxConstraints.tightFor(
              width: Design.target,
              height: Design.target,
            ),
            onPressed: widget.editable
                ? () => _showAttachmentSheet(includeDictation: narrow)
                : null,
            color: controlColor,
            disabledColor: disabledColor,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: const DesignIcon('plus'),
          ),
        Expanded(
          child: TextField(
            controller: _controller,
            focusNode: widget.focusNode,
            contextMenuBuilder: (context, state) =>
                AdaptiveTextSelectionToolbar.buttonItems(
                  anchors: state.contextMenuAnchors,
                  buttonItems: [
                    ...state.contextMenuButtonItems.where(
                      (item) => item.type != ContextMenuButtonType.paste,
                    ),
                    if (widget.editable)
                      ContextMenuButtonItem(
                        type: ContextMenuButtonType.paste,
                        onPressed: () {
                          state.hideToolbar();
                          unawaited(_paste());
                        },
                      ),
                  ],
                ),
            // Read-only rather than disabled keeps focus, selection, and
            // copying available during a brief local mutation.
            readOnly: !widget.editable,
            minLines: 1,
            maxLines: null,
            keyboardType: TextInputType.multiline,
            textCapitalization: TextCapitalization.sentences,
            style: theme.textTheme.bodyLarge,
            cursorColor: colors.primary,
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: theme.textTheme.bodyLarge?.copyWith(
                color: colors.onSurfaceVariant,
              ),
              filled: false,
              isDense: widget.compact,
              contentPadding: EdgeInsets.symmetric(
                horizontal: Design.space2,
                vertical: widget.compact ? 6 : 9,
              ),
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
            ),
          ),
        ),
        const SizedBox(width: Design.space1),
        if (showMic) ...<Widget>[
          IconButton(
            tooltip: _dictating ? 'Stop dictation' : 'Dictate message',
            constraints: const BoxConstraints.tightFor(
              width: Design.target,
              height: Design.target,
            ),
            onPressed: _dictating || _canDictate ? _toggleDictation : null,
            color: _dictating ? colors.error : controlColor,
            disabledColor: disabledColor,
            style: IconButton.styleFrom(
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            icon: _dictating
                ? const Icon(Icons.stop_circle_outlined, size: 22)
                : const Icon(Icons.mic_none_outlined, size: 22),
          ),
          const SizedBox(width: Design.space1),
        ],
        if (widget.isStreaming) ...<Widget>[
          IconButton.filled(
            tooltip: 'Stop response',
            constraints: const BoxConstraints.tightFor(
              width: Design.target,
              height: Design.target,
            ),
            onPressed: widget.onStop,
            style: _primaryActionStyle(colors),
            icon: const Icon(Icons.stop_rounded, size: 21),
          ),
          if (_canSend) ...<Widget>[
            const SizedBox(width: Design.space1),
            IconButton.filled(
              tooltip: 'Queue message',
              constraints: const BoxConstraints.tightFor(
                width: Design.target,
                height: Design.target,
              ),
              onPressed: _send,
              style: _primaryActionStyle(colors),
              icon: DesignIcon(
                'send',
                size: 20,
                color: _canSend
                    ? colors.surface
                    : colors.onSurface.withValues(alpha: .38),
              ),
            ),
          ],
        ] else
          IconButton.filled(
            tooltip: widget.isQueueing ? 'Queue message' : 'Send',
            constraints: const BoxConstraints.tightFor(
              width: Design.target,
              height: Design.target,
            ),
            onPressed: _canSend ? _send : null,
            style: _primaryActionStyle(colors),
            icon: DesignIcon(
              'send',
              size: 20,
              color: _canSend
                  ? colors.surface
                  : colors.onSurface.withValues(alpha: .38),
            ),
          ),
      ],
    );
  }

  ButtonStyle _primaryActionStyle(ColorScheme colors) => IconButton.styleFrom(
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: EdgeInsets.zero,
    backgroundColor: colors.onSurface,
    foregroundColor: colors.surface,
    disabledBackgroundColor: colors.onSurface.withValues(alpha: .12),
    disabledForegroundColor: colors.onSurface.withValues(alpha: .38),
  );
}

class _Caption extends StatelessWidget {
  const _Caption({
    required this.text,
    required this.color,
    this.liveRegion = false,
  });
  final String text;
  final Color color;
  final bool liveRegion;

  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: liveRegion,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(Design.space2, 0, Design.space2, 3),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    ),
  );
}
