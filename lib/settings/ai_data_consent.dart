import 'package:flutter/material.dart';

import '../data/settings_store.dart';
import 'help_about.dart';

/// This decision is separate from saving an address or testing a connection.
/// Callers persist permission only after the user explicitly allows sharing.
Future<bool> showAiDataConsent(
  BuildContext context,
  ServerProfile profile,
) async {
  final shared = profile.protocol == ServerProtocol.openWebUi;
  final service = switch (profile.protocol) {
    ServerProtocol.ollama => 'Ollama',
    ServerProtocol.openAiCompatible => 'OpenAI-compatible API',
    ServerProtocol.openWebUi => 'Open WebUI',
  };
  return await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Allow AI data sharing?'),
          scrollable: true,
          content: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Recipient: ${profile.name} ($service)',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SelectableText(profile.baseUrl),
              const SizedBox(height: 16),
              const Text(
                'To generate AI replies, this server receives your messages, '
                'chat history, instructions, images, document content, and '
                'model settings. These may contain personal information.',
              ),
              const SizedBox(height: 12),
              Text(
                shared
                    ? 'Your sign-in email and password, or API key, and any '
                          'gateway credentials are sent to this server to access '
                          'your account. Chats, files, titles, and folders are '
                          'also stored and synchronized there.'
                    : 'Any API key and gateway credentials you provide are sent '
                          'to this server to authenticate requests. Connection '
                          'checks send credentials but no chat content.',
              ),
              const SizedBox(height: 12),
              Text(
                'The operator of ${Uri.parse(profile.baseUrl).host} controls '
                'processing, retention, and onward sharing with its AI providers. '
                'Only allow an operator whose privacy practices you trust.',
              ),
              if (shared) ...[
                const SizedBox(height: 12),
                const Text(
                  'Tools and web search you enable may share content with other '
                  'services configured by that operator.',
                ),
              ],
              const SizedBox(height: 12),
              Text(
                shared
                    ? 'You can withdraw permission by signing out in Shared chats. '
                          'This does not delete data already on the server.'
                    : 'You can withdraw permission in Settings → Connections. '
                          'Saved chats stay on this device; data already sent may '
                          'remain on the server.',
              ),
              TextButton(
                onPressed: () =>
                    openExternalUrl(dialogContext, kPrivacyPolicyUrl),
                child: const Text('Privacy policy'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Don’t allow'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Allow data sharing'),
            ),
          ],
        ),
      ) ==
      true;
}
