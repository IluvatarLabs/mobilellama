import 'dart:io';

import 'package:flutter/material.dart';

Future<void> showChatImage(BuildContext context, String reference) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (_) => _ChatImageViewer(reference: reference),
      ),
    );

class _ChatImageViewer extends StatelessWidget {
  const _ChatImageViewer({required this.reference});

  final String reference;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: colors.scrim,
      body: SafeArea(
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            Semantics(
              label: 'Attached image',
              image: true,
              child: InteractiveViewer(
                minScale: .75,
                maxScale: 5,
                child: Center(
                  child: Image.file(
                    File(reference),
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.contain,
                    errorBuilder: (_, _, _) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white,
                        size: 40,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filledTonal(
                tooltip: 'Close image',
                constraints: const BoxConstraints.tightFor(
                  width: 48,
                  height: 48,
                ),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
