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
            'Shared chats also cache downloaded server history and files. '
            'Deleting chats removes their local copies from this phone.',
      ),
      (
        'Credentials',
        'Server API keys, access tokens, custom gateway-header values, and the '
            'Ollama cloud API key are stored in the iOS Keychain. A shared-server '
            'password is used to sign in and is not retained afterward. '
            'Credentials are not included in chat backups or iCloud sync.',
      ),
      (
        'Permission for your AI server',
        'Before first contacting a configured AI destination, MobileLlama '
            'shows its name, server type, exact address, the data and purpose, '
            'and asks you to allow sharing. Permission applies only to that '
            'protocol and address; changing the address requires a new choice. '
            'Saving without connecting does not contact the server.',
      ),
      (
        'Direct connections',
        'A connection check can send configured credentials and gateway headers '
            'and asks only for server, model, and capability information. '
            'Generating a response can send your current message, selected '
            'history, instructions, model settings and tool state, attached '
            'images and document contents, and web-search results included in '
            'the chat.',
      ),
      (
        'Shared chats',
        'Signing in sends your email and password, API key, or gateway '
            'credentials to the Open WebUI server you selected. MobileLlama '
            'accesses account identity, server chats, titles, folders, and files '
            'to display and synchronize them. Prompts, selected history, '
            'instructions, settings, resources, and uploaded attachments are '
            'sent there to generate and store responses.',
      ),
      (
        'Your server’s operator',
        'The named operator may be you, your organization, or an independent AI '
            'service. It controls server-side logging, model training, retention, '
            'deletion, onward sharing, and any AI providers behind the server. '
            'MobileLlama does not choose those operators or receive your chats '
            'and cannot guarantee an arbitrary server’s practices. Allow only '
            'operators whose privacy policy and terms you accept.',
      ),
      (
        'Withdraw permission',
        'For a direct connection, use Settings → Connections → Withdraw AI data '
            'sharing. Saved local chats and drafts remain. For Shared chats, '
            'sign out to remove that account’s credentials, cached chats and '
            'files, drafts, queues, and pending requests from this phone. These '
            'actions stop future requests and require permission again, but do '
            'not delete data already stored by the server. Use the server’s '
            'controls or contact its operator for server-side deletion.',
      ),
      (
        'Web search (optional)',
        'Off unless you turn it on and approve its disclosure. Search terms and '
            'page addresses are sent with your Ollama cloud API key to Ollama’s '
            'cloud service at ollama.com. Returned results and fetched page '
            'content can be added to the chat sent to your selected AI server. '
            'Turn off Web search to stop future web-search requests.',
      ),
      (
        'iCloud sync (optional)',
        'Off unless you turn it on. Chats and attachments are then stored in '
            'your private Apple iCloud account under Apple’s privacy policy. '
            'API keys and unsent drafts stay on this phone. Turn off iCloud sync '
            'to stop future synchronization; use Apple’s account and storage '
            'controls for data already stored there.',
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
        'No MobileLlama service or analytics',
        'The developers do not operate an account or AI service for MobileLlama '
            'and do not receive the data sent to a server you choose. The app '
            'includes no analytics, advertising, or crash-reporting service. '
            'MobileLlama uses no third-party processor to receive AI data on its '
            'behalf. Any provider MobileLlama selects in the future must provide '
            'the same or equal protection described in the privacy policy. '
            'User-selected servers are independent services with their own '
            'privacy policies.',
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
