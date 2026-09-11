import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../ui/design.dart';
import 'speech_actions.dart';

/// A bottom composer with one expanding text field and explicit media/action
/// controls. Transport state remains owned by the caller.
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.onSend,
    required this.onStop,
    this.onPickImage,
    this.onTakePhoto,
    this.onPickDocument,
    this.imagesEnabled = true,
    this.dictationEngine,
    this.controller,
    this.isStreaming = false,
    this.isQueueing = false,
    this.enabled = true,
    this.hintText = 'Message',
    this.draftScopeRevision = 0,
    this.draftText = '',
    this.onDraftChanged,
    this.sendEnabled = true,
    this.hasAttachments = false,
  });

  final Future<bool> Function(String) onSend;
  final VoidCallback onStop;
  final VoidCallback? onPickImage;
  final VoidCallback? onTakePhoto;
  final VoidCallback? onPickDocument;
  final bool imagesEnabled;
  final DictationEngine? dictationEngine;
  final TextEditingController? controller;
  final bool isStreaming;
  final bool isQueueing;
  final bool enabled;
  final String hintText;
  final int draftScopeRevision;
  final String draftText;
  final ValueChanged<String>? onDraftChanged;
  final bool sendEnabled;
  final bool hasAttachments;

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

  bool get _canSend =>
      widget.enabled &&
      widget.sendEnabled &&
      (_controller.text.trim().isNotEmpty || widget.hasAttachments);

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
    if ((oldWidget.enabled && !widget.enabled) ||
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
    if (!widget.enabled || widget.isStreaming) return;

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

  Future<void> _showAttachmentSheet() async {
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dictationSession++;
    unawaited(_dictation.cancel());
    _removeController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final surfaceEnabled = widget.enabled;
    final controlColor = surfaceEnabled
        ? colors.onSurfaceVariant
        : colors.onSurfaceVariant.withValues(alpha: 0.4);

    return Material(
      color: colors.surfaceContainerLowest,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Design.composer(context),
              border: Border.all(color: Design.line(context)),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 7, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      if (widget.onPickImage != null ||
                          widget.onTakePhoto != null ||
                          widget.onPickDocument != null)
                        IconButton(
                          tooltip: 'Add attachment',
                          constraints: const BoxConstraints.tightFor(
                            width: 44,
                            height: 44,
                          ),
                          onPressed: widget.enabled
                              ? _showAttachmentSheet
                              : null,
                          color: controlColor,
                          disabledColor: colors.onSurfaceVariant.withValues(
                            alpha: 0.35,
                          ),
                          style: IconButton.styleFrom(
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: const DesignIcon('plus'),
                        ),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          enabled: surfaceEnabled,
                          minLines: 1,
                          maxLines: 6,
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
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 9,
                            ),
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: _listening || _startingDictation
                            ? 'Stop dictation'
                            : 'Dictate message',
                        constraints: const BoxConstraints.tightFor(
                          width: 44,
                          height: 44,
                        ),
                        onPressed: widget.enabled && !widget.isStreaming
                            ? _toggleDictation
                            : null,
                        color: _listening || _startingDictation
                            ? colors.error
                            : controlColor,
                        disabledColor: colors.onSurfaceVariant.withValues(
                          alpha: 0.35,
                        ),
                        style: IconButton.styleFrom(
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: _listening || _startingDictation
                            ? const Icon(Icons.stop_circle_outlined, size: 22)
                            : const Icon(Icons.mic_none_outlined, size: 22),
                      ),
                      const SizedBox(width: 4),
                      if (widget.isStreaming) ...<Widget>[
                        IconButton.filled(
                          tooltip: 'Stop response',
                          constraints: const BoxConstraints.tightFor(
                            width: 44,
                            height: 44,
                          ),
                          onPressed: widget.onStop,
                          style: _primaryActionStyle(colors),
                          icon: const Icon(Icons.stop_rounded, size: 21),
                        ),
                        if (_canSend) ...<Widget>[
                          const SizedBox(width: 4),
                          IconButton.filled(
                            tooltip: 'Queue message',
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 44,
                            ),
                            onPressed: _send,
                            style: _primaryActionStyle(colors),
                            icon: const DesignIcon('send', size: 20),
                          ),
                        ],
                      ] else
                        IconButton.filled(
                          tooltip: widget.isQueueing ? 'Queue message' : 'Send',
                          constraints: const BoxConstraints.tightFor(
                            width: 44,
                            height: 44,
                          ),
                          onPressed: _canSend ? _send : null,
                          style: _primaryActionStyle(colors),
                          icon: const DesignIcon('send', size: 20),
                        ),
                    ],
                  ),
                  if (_listening || _startingDictation)
                    Semantics(
                      liveRegion: true,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          _startingDictation
                              ? 'Starting dictation…'
                              : 'Listening…',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: colors.error,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  ButtonStyle _primaryActionStyle(ColorScheme colors) => IconButton.styleFrom(
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: EdgeInsets.zero,
    backgroundColor: colors.primary,
    foregroundColor: colors.onPrimary,
    disabledBackgroundColor: colors.primary.withValues(alpha: .45),
    disabledForegroundColor: colors.onPrimary,
  );
}
