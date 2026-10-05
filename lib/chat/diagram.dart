import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../ui/design.dart';

/// An isolated local renderer. Model text is passed as a string, never HTML.
class AnswerDiagram extends StatefulWidget {
  const AnswerDiagram({super.key, required this.source, this.expanded = false});
  final String source;
  final bool expanded;

  static bool supports(String source) =>
      source.length <= 65536 &&
      !RegExp(r'^\s*---', multiLine: true).hasMatch(source) &&
      !RegExp(r'%%\s*\{').hasMatch(source) &&
      RegExp(
        r'^\s*(?:(?:%%[^\n]*\n)\s*)*(?:flowchart|graph|sequenceDiagram|classDiagram|stateDiagram(?:-v2)?|erDiagram|pie)\b',
      ).hasMatch(source);

  @override
  State<AnswerDiagram> createState() => _AnswerDiagramState();
}

class _AnswerDiagramState extends State<AnswerDiagram> {
  WebViewController? _web;
  bool _failed = false;
  bool _ready = false;
  bool _sourceVisible = false;
  bool? _dark;
  int _renderRevision = 0;
  static const _platform = MethodChannel('app.mobollama/renderer');

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dark = Theme.of(context).brightness == Brightness.dark;
    if (_dark == dark) return;
    _dark = dark;
    if (_web == null && !_failed) {
      unawaited(_initialize());
    } else if (_web != null) {
      unawaited(_render());
    }
  }

  Future<void> _initialize() async {
    try {
      if (!AnswerDiagram.supports(widget.source) ||
          !Platform.isIOS ||
          await _platform.invokeMethod<bool>('supported') != true) {
        if (mounted) setState(() => _failed = true);
        return;
      }
      final web = WebViewController();
      await web.setJavaScriptMode(JavaScriptMode.unrestricted);
      await web.setBackgroundColor(Colors.transparent);
      await web.enableZoom(widget.expanded);
      await web.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return uri?.scheme == 'file' &&
                    uri!.path.endsWith('/assets/mermaid/index.html')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onPageFinished: (_) => unawaited(_render()),
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() => _failed = true);
            }
          },
        ),
      );
      if (!mounted) return;
      setState(() => _web = web);
      await web.loadFlutterAsset('assets/mermaid/index.html');
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _render() async {
    final web = _web;
    if (web == null || !mounted) return;
    final revision = ++_renderRevision;
    try {
      await web.runJavaScript(
        'window.renderDiagram(${jsonEncode(widget.source)}, ${_dark == true});',
      );
      for (var attempt = 0; attempt < 100; attempt++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (!mounted || revision != _renderRevision) return;
        final status = await web.runJavaScriptReturningResult(
          'window.diagramStatus',
        );
        if ('$status'.replaceAll('"', '') == 'complete') {
          setState(() => _ready = true);
          return;
        }
        if ('$status'.replaceAll('"', '') == 'failed') break;
      }
    } on Object {
      /* Source remains available when WebKit cannot render. */
    }
    if (mounted && revision == _renderRevision) setState(() => _failed = true);
  }

  @override
  void didUpdateWidget(covariant AnswerDiagram oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.source != oldWidget.source) {
      _ready = false;
      _failed = !AnswerDiagram.supports(widget.source);
      if (!_failed) unawaited(_web == null ? _initialize() : _render());
    }
  }

  Widget _source() => SingleChildScrollView(
    padding: const EdgeInsets.all(12),
    child: SelectableText(
      widget.source,
      style: const TextStyle(fontFamily: 'monospace'),
    ),
  );

  @override
  void dispose() {
    _renderRevision++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final preview = SizedBox(
      height: widget.expanded ? null : 240,
      child: Stack(
        children: [
          if (_web != null)
            ExcludeSemantics(child: WebViewWidget(controller: _web!)),
          if (!_ready) const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow,
        border: Border.all(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(Design.radiusMedium),
      ),
      child: Column(
        mainAxisSize: widget.expanded ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('Diagram'),
              ),
              TextButton(
                onPressed: () =>
                    setState(() => _sourceVisible = !_sourceVisible),
                child: const Text('Source'),
              ),
              IconButton(
                tooltip: 'Copy diagram source',
                onPressed: () =>
                    Clipboard.setData(ClipboardData(text: widget.source)),
                icon: const Icon(Icons.content_copy_outlined, size: 18),
              ),
              if (!widget.expanded && !_failed)
                IconButton(
                  tooltip: 'Expand diagram',
                  icon: const Icon(Icons.open_in_full, size: 18),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (context) => Scaffold(
                        appBar: AppBar(title: const Text('Diagram')),
                        body: SafeArea(
                          child: AnswerDiagram(
                            source: widget.source,
                            expanded: true,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          if (_failed || _sourceVisible)
            if (widget.expanded)
              Expanded(child: _source())
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: _source(),
              )
          else if (widget.expanded)
            Expanded(child: preview)
          else
            preview,
          if (_failed)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Preview unavailable. Diagram source is shown above.',
              ),
            ),
        ],
      ),
    );
  }
}
