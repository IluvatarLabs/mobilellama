import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/design.dart';

/// Release configuration input: the owner's privacy policy URL. The Privacy
/// policy row stays hidden while this is empty.
const kPrivacyPolicyUrl =
    'https://github.com/IluvatarLabs/mobilellama/blob/main/PRIVACY.md';

const kIssuesUrl = 'https://github.com/IluvatarLabs/mobilellama/issues';

const _legalese = 'Open source under the Apache License 2.0.';

/// Opens [url] in the browser; reports failure instead of failing silently.
Future<void> openExternalUrl(BuildContext context, String url) async {
  var opened = false;
  try {
    opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
  } on Object {
    opened = false;
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Could not open $url')));
  }
}

class _InfoPage extends StatelessWidget {
  const _InfoPage({required this.title, required this.sections});
  final String title;
  final List<(String, String)> sections;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Design.panel(context),
      appBar: AppBar(
        backgroundColor: Design.panel(context),
        title: Text(title),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Design.gutter,
            Design.space2,
            Design.gutter,
            Design.space5,
          ),
          children: <Widget>[
            for (final (heading, body) in sections) ...<Widget>[
              Padding(
                padding: const EdgeInsets.only(
                  top: Design.gutter,
                  bottom: Design.space2,
                ),
                child: Semantics(
                  header: true,
                  child: Text(
                    heading,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              Text(body, style: theme.textTheme.bodyLarge),
            ],
          ],
        ),
      ),
    );
  }
}

/// Offline setup help, adapted from the README's guidance.
class ConnectionHelpPage extends StatelessWidget {
  const ConnectionHelpPage({super.key});

  @override
  Widget build(BuildContext context) => const _InfoPage(
    title: 'Connection help',
    sections: <(String, String)>[
      (
        'You need a server',
        'MobileLlama is a chat app. Models run on a server you choose, such '
            'as Ollama on your Mac or home server, or a hosted '
            'OpenAI-compatible API. The server must be running and reachable '
            'from this phone.',
      ),
      (
        'Connection types',
        'Ollama: connects to an Ollama server, usually on port 11434, for '
            'example http://192.168.1.20:11434.\n\n'
            'OpenAI-compatible: connects to a server that provides the OpenAI '
            'chat API. Enter its exact API root, for example '
            'https://example.com/v1.',
      ),
      (
        'LAN address, not localhost',
        'On an iPhone, localhost means this phone. Use your server’s LAN '
            'address or hostname, such as 192.168.1.20 or mac.local. Your '
            'phone and server must be on the same network, or the server must '
            'be reachable over the internet.',
      ),
      (
        'Let Ollama accept network connections',
        'Ollama listens only on its own computer by default. To reach it '
            'from your phone, start it with OLLAMA_HOST set to 0.0.0.0, then '
            'use that computer’s LAN address. When iOS asks, allow '
            'MobileLlama to find devices on your local network.',
      ),
      (
        'HTTP and HTTPS',
        'HTTP is allowed only for local addresses and is unencrypted; you '
            'confirm this when saving. Use HTTPS for servers on the internet.',
      ),
      (
        'API keys are optional',
        'An OpenAI-compatible server may require an API key. It is stored '
            'securely on this phone and sent only to that server. Web search '
            'uses a separate Ollama cloud API key, set in Web search.',
      ),
      (
        'Save or Save and connect',
        'Save keeps a connection without contacting the server, for example '
            'while it is offline. Save and connect also checks the server so '
            'you can choose a model.',
      ),
    ],
  );
}

/// In-app privacy information. Each statement reflects the app's actual
/// data flows; see the final report for where each was verified.
class PrivacyInfoPage extends StatelessWidget {
  const PrivacyInfoPage({super.key});

  @override
  Widget build(BuildContext context) => const _InfoPage(
    title: 'Privacy',
    sections: <(String, String)>[
      (
        'Stored on this phone',
        'Chats, drafts, queued follow-ups, earlier versions of edited chats, '
            'and chat settings are stored in the app’s local database. '
            'Attached images and documents are kept in the app’s storage. '
            'Deleting chats removes them from this phone.',
      ),
      (
        'API keys',
        'Server API keys and the Ollama cloud API key are stored in the iOS '
            'Keychain. They are not included in chat backups or iCloud sync.',
      ),
      (
        'Sent to your server',
        'When you send a message, the chat’s messages, instructions, '
            'settings, and attachments are sent to the server selected for '
            'that chat. That server’s operator controls how it is processed '
            'and how long it is kept. Checking a connection only asks the '
            'server for its version, models, and model capabilities.',
      ),
      (
        'Web search (optional)',
        'Off unless you turn it on. When a model searches, search terms and '
            'page addresses are sent to Ollama’s cloud service (ollama.com) '
            'with your Ollama cloud API key, and the results are added to the '
            'chat sent to your server.',
      ),
      (
        'iCloud sync (optional)',
        'Off unless you turn it on. Chats and attachments are then stored in '
            'your private iCloud account. API keys and unsent drafts stay on '
            'this phone.',
      ),
      (
        'Dictation and read aloud',
        'Dictation uses Apple’s speech recognition, which may send audio to '
            'Apple depending on your device and language. The microphone and '
            'speech recognition permissions are requested only when you '
            'dictate. Read aloud uses the voices built into iOS.',
      ),
      (
        'Backups',
        'A chat backup is created only when you ask, and goes only where you '
            'send it from the share sheet. It excludes API keys and unsent '
            'drafts.',
      ),
      (
        'No accounts or analytics',
        'MobileLlama has no account system and includes no analytics, '
            'advertising, or crash-reporting service.',
      ),
    ],
  );
}

/// App name and version from the installed build, plus licenses.
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: Design.panel(context),
      appBar: AppBar(
        backgroundColor: Design.panel(context),
        title: const Text('About'),
      ),
      body: SafeArea(
        top: false,
        child: FutureBuilder<PackageInfo>(
          future: _info,
          builder: (context, snapshot) {
            final info = snapshot.data;
            final name = info == null || info.appName.isEmpty
                ? 'MobileLlama'
                : info.appName;
            final version = info == null
                ? (snapshot.hasError ? 'Version unavailable' : '')
                : 'Version ${info.version} (${info.buildNumber})';
            return ListView(
              padding: const EdgeInsets.all(Design.gutter),
              children: <Widget>[
                const SizedBox(height: Design.space5),
                Center(
                  child: Image.asset(
                    'assets/mobilellama-icon.png',
                    width: 88,
                    height: 88,
                    excludeFromSemantics: true,
                  ),
                ),
                const SizedBox(height: Design.gutter),
                Text(
                  name,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: Design.space1),
                Text(
                  version,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: Design.space2),
                const Text(_legalese, textAlign: TextAlign.center),
                const SizedBox(height: Design.space5),
                Material(
                  color: Design.group(context),
                  borderRadius: BorderRadius.circular(Design.radiusMedium),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    minTileHeight: 56,
                    title: const Text('Open-source licenses'),
                    trailing: const DesignIcon('chevron', size: 20),
                    onTap: () => showLicensePage(
                      context: context,
                      applicationName: name,
                      applicationVersion: info == null
                          ? null
                          : '${info.version} (${info.buildNumber})',
                      applicationLegalese: _legalese,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
