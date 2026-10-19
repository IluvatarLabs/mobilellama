import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'client.dart';

/// Structured server image artifacts only. Markdown image URLs never enter
/// this loader and credentials never follow redirects or leave the file API.
class WebUiArtifacts extends StatelessWidget {
  const WebUiArtifacts({super.key, required this.session, required this.node});
  final WebUiSession session;
  final Map<String, dynamic> node;

  static List<String> references(Map node) {
    final files = <Map>[
      ...(node['files'] as List? ?? []).whereType<Map>(),
      for (final item in (node['output'] as List? ?? []).whereType<Map>()) ...[
        ...(item['files'] as List? ?? []).whereType<Map>(),
        for (final part
            in (item['output'] is List ? item['output'] as List : const [])
                .whereType<Map>())
          if (part['type'] == 'input_image' && part['image_url'] is String)
            {'type': 'image', 'url': part['image_url']},
      ],
    ];
    return files
        .where(
          (file) =>
              file['type'] == 'image' ||
              (file['content_type'] as String? ?? '').startsWith('image/'),
        )
        .map((file) => file['url'])
        .whereType<String>()
        .toSet()
        .toList();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final reference in references(node))
        _ServerImage(
          key: ValueKey('${session.profileId}:$reference'),
          session: session,
          reference: reference,
        ),
    ],
  );
}

class _ServerImage extends StatefulWidget {
  const _ServerImage({
    super.key,
    required this.session,
    required this.reference,
  });
  final WebUiSession session;
  final String reference;
  @override
  State<_ServerImage> createState() => _ServerImageState();
}

class _ServerImageState extends State<_ServerImage> {
  late Future<Uint8List> _bytes;
  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    _bytes = Future.sync(
      () => widget.session.client.fileBytes(
        widget.reference,
        widget.session.capture(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.session,
    builder: (context, _) {
      if (widget.session.locked) {
        return const Text('Sign in again to view this image.');
      }
      return FutureBuilder<Uint8List>(
        future: _bytes,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return TextButton.icon(
              onPressed: () => setState(_load),
              icon: const Icon(Icons.broken_image_outlined),
              label: const Text('Image unavailable · Retry'),
            );
          }
          if (!snapshot.hasData) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(),
              ),
            );
          }
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Semantics(
              button: true,
              label: 'Open server image',
              child: InkWell(
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (context) => AnimatedBuilder(
                    animation: widget.session,
                    builder: (context, _) => Dialog.fullscreen(
                      child: Scaffold(
                        appBar: AppBar(title: const Text('Server image')),
                        body: widget.session.locked
                            ? const Center(
                                child: Text(
                                  'Sign in again to view this image.',
                                ),
                              )
                            : Center(
                                child: InteractiveViewer(
                                  minScale: .5,
                                  maxScale: 6,
                                  child: Image.memory(
                                    snapshot.data!,
                                    fit: BoxFit.contain,
                                  ),
                                ),
                              ),
                      ),
                    ),
                  ),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.memory(
                    snapshot.data!,
                    height: 240,
                    fit: BoxFit.contain,
                    cacheWidth: 1200,
                    errorBuilder: (_, __, ___) => const Text(
                      'The server file could not be displayed as an image.',
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
