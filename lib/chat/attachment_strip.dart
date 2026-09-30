import 'dart:io';

import 'package:flutter/material.dart';

import '../ui/design.dart';

class PendingImageStrip extends StatelessWidget {
  const PendingImageStrip({
    super.key,
    required this.references,
    required this.onRemove,
  });

  final List<String> references;
  final Future<void> Function([String? reference]) onRemove;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SizedBox(
      height: 90,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(Design.gutter, 6, Design.gutter, 0),
        itemCount: references.length,
        separatorBuilder: (_, _) => const SizedBox(width: 6),
        itemBuilder: (context, index) {
          final reference = references[index];
          return SizedBox(
            width: 84,
            height: 84,
            child: Stack(
              children: <Widget>[
                Positioned(
                  left: 0,
                  bottom: 0,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Design.radiusSmall),
                    child: Image.file(
                      File(reference),
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => ColoredBox(
                        color: colors.surfaceContainerHighest,
                        child: const SizedBox(
                          width: 72,
                          height: 72,
                          child: Icon(Icons.broken_image_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 0,
                  top: 0,
                  child: IconButton.filledTonal(
                    tooltip: 'Remove image ${index + 1}',
                    constraints: const BoxConstraints.tightFor(
                      width: 44,
                      height: 44,
                    ),
                    onPressed: () => onRemove(reference),
                    icon: const Icon(Icons.close, size: 18),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
