import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../domain/source_reference.dart';
import '../ui/design.dart';

class AnswerSources extends StatelessWidget {
  const AnswerSources({super.key, required this.sources, this.onOpenFile});
  final List<SourceReference> sources;
  final Future<void> Function(SourceReference)? onOpenFile;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      for (var i = 0; i < sources.length; i++)
        ActionChip(
          label: Text(
            '${i + 1}. ${sources[i].title}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            useSafeArea: true,
            builder: (context) => KeyboardSafeSheet(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SheetHandle(),
                  const SheetHeading(
                    title: 'Source',
                    closeLabel: 'Close source',
                  ),
                  SelectableText(
                    sources[i].title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  if (sources[i].excerpt != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: SelectableText(sources[i].excerpt!),
                    ),
                  if (sources[i].fileId != null && onOpenFile != null)
                    FilledButton(
                      onPressed: () => onOpenFile!(sources[i]),
                      child: const Text('Open source file'),
                    )
                  else if (sources[i].url != null) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: SelectableText(sources[i].url!),
                    ),
                    FilledButton(
                      onPressed: () async {
                        final uri = Uri.tryParse(sources[i].url!);
                        if (uri == null ||
                            !{'https', 'http'}.contains(uri.scheme) ||
                            uri.userInfo.isNotEmpty) {
                          return;
                        }
                        final opened = await launchUrl(
                          uri,
                          mode: LaunchMode.externalApplication,
                        );
                        if (!opened && context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('This source could not be opened.'),
                            ),
                          );
                        }
                      },
                      child: const Text('Open source'),
                    ),
                  ] else
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'This source requires access through its original service.',
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}
