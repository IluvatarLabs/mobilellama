import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../data/chat_backup.dart';
import '../domain/message.dart';
import 'client.dart';
import 'conversation.dart';
import 'resources.dart';
import 'store.dart';

/// Inert, user-requested copies. No remote identifiers, credentials, provider
/// transcript, or executable tool records are passed to the local importer.
final class WebUiExport {
  const WebUiExport(this.session, this.store);
  final WebUiSession session;
  final WebUiStore store;

  Future<WebUiConversation> completeBranch(String id) async {
    final lease = session.capture();
    final fresh = await store.refreshChat(session, id);
    lease.check();
    final conversation = WebUiConversation(fresh);
    conversation
        .branch(); // Missing ancestors must fail before calling this complete.
    return conversation;
  }

  bool _privateUrl(String? value) {
    if (value == null) return false;
    final uri = Uri.tryParse(value);
    return value.contains('/api/v1/files/') ||
        (uri != null && uri.hasScheme && uri.host == session.client.root.host);
  }

  String _text(Map node) {
    var content = webUiMessageText(node);
    // Keep readable labels while disabling account-bound inline URLs. General
    // public links remain content; credentials and operational IDs are not copied.
    content = content.replaceAllMapped(RegExp(r'!?\[([^\]]*)\]\(([^\s)]+)\)'), (
      match,
    ) {
      final raw = match.group(2)!;
      final uri = Uri.tryParse(raw);
      final private =
          raw.contains('/api/v1/files/') ||
          uri != null && uri.hasScheme && uri.host == session.client.root.host;
      return private
          ? '${match.group(1)!.isEmpty ? 'Attachment' : match.group(1)} [account-bound source unavailable]'
          : match.group(0)!;
    });
    final sources = WebUiResources.sources(node);
    if (sources.isNotEmpty) {
      content +=
          '\n\nSources:\n${sources.map((s) => '- ${s.title}${s.fileId != null || _privateUrl(s.url)
              ? ' [account-bound source unavailable]'
              : s.url != null
              ? ' (${s.url})'
              : ''}').join('\n')}';
    }
    if ((node['files'] as List? ?? []).isNotEmpty) {
      content +=
          '\n\n[Server attachments are unavailable in this text snapshot.]';
    }
    return content;
  }

  String markdown(WebUiConversation conversation, {bool incomplete = false}) =>
      '# ${conversation.title}\n\n${incomplete ? 'Incomplete cached snapshot' : 'Active branch'} · exported from MobileLlama. Server attachments and private links require the original account.\n\n${conversation.branch().map((node) => '## ${node['role'] == 'user'
          ? 'You'
          : node['role'] == 'system'
          ? 'System'
          : 'Assistant'}\n\n${_text(node)}').join('\n\n')}\n';

  String portableJson(WebUiConversation conversation) {
    final now = DateTime.now().toUtc().toIso8601String();
    const uuid = Uuid();
    final profile = uuid.v4();
    final branch = conversation.branch();
    return jsonEncode({
      'format': ChatBackup.format,
      'version': 1,
      'exportedAt': now,
      'serverProfiles': [
        {
          'id': profile,
          'name': 'Choose a local inference destination',
          'protocol': 'localSnapshot',
          'baseUrl': 'https://destination.invalid',
        },
      ],
      'conversations': [
        {
          'id': uuid.v4(),
          'serverProfileId': profile,
          'title': '${conversation.title} (local copy)',
          'selectedModel': '',
          'systemPrompt': '',
          'generationOptions': {},
          'isPinned': false,
          'isArchived': false,
          'isRenamed': true,
          'createdAt': now,
          'updatedAt': now,
          'messages': [
            for (var i = 0; i < branch.length; i++)
              {
                'id': uuid.v4(),
                'position': i,
                'role': branch[i]['role'] == 'system'
                    ? 'system'
                    : branch[i]['role'] == 'user'
                    ? 'user'
                    : 'assistant',
                'status': branch[i]['done'] == false
                    ? MessageStatus.interrupted.name
                    : MessageStatus.complete.name,
                'content': _text(branch[i]),
                'images': [],
                'documents': [],
                'toolCalls': [],
                'toolResults': [],
                'createdAt': now,
                'updatedAt': now,
              },
          ],
        },
      ],
    });
  }
}
