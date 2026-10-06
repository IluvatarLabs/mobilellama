import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../chat/chat_controller.dart' show insecureHttpHostAllowed;
import '../data/settings_store.dart';
import '../ui/design.dart';
import 'accounts.dart';
import 'client.dart';
import 'screen.dart';
import 'workspace.dart';

class WebUiAccountsPage extends StatefulWidget {
  const WebUiAccountsPage({super.key, required this.accounts});
  final WebUiAccounts accounts;
  @override
  State<WebUiAccountsPage> createState() => _WebUiAccountsPageState();
}

class _WebUiAccountsPageState extends State<WebUiAccountsPage> {
  String? _opening, _error;
  Future<void> _forget(ServerProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Sign out of ${profile.name}?'),
        content: const Text(
          'Remove this account’s cached chats, files, unsent drafts, queues, pending requests, and credentials from this device. Server history remains. This also works when credentials have expired.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.accounts.forgetStoredAccount(profile.id);
    } on Object {
      if (mounted) {
        setState(() => _error = 'Local sign-out could not finish. Try again.');
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _connect([ServerProfile? profile]) async {
    if (_opening != null) return;
    WebUiSession? session;
    if (profile != null) {
      setState(() {
        _opening = profile.id;
        _error = null;
      });
      try {
        session = await widget.accounts.open(profile);
      } on Object {
        /* Reauthenticate explicitly; never unlock from a saved token alone. */
      }
      if (!mounted) {
        session?.lock();
        session?.client.close();
        return;
      }
      setState(() => _opening = null);
    }
    session ??= await Navigator.push<WebUiSession>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            WebUiSignInPage(accounts: widget.accounts, profile: profile),
      ),
    );
    if (!mounted || session == null) {
      session?.lock();
      session?.client.close();
      return;
    }
    final workspace = WebUiWorkspace(widget.accounts, session);
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => WebUiScreen(workspace: workspace)),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Shared chats')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              'Open WebUI',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text(
                'Continue the same conversations on your phone and your server. Your account’s history stays on that server; downloaded chats are cached on this device.',
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            for (final profile in widget.accounts.profiles)
              ListTile(
                title: Text(profile.name),
                subtitle: Text(profile.baseUrl),
                trailing: _opening == profile.id
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(),
                      )
                    : PopupMenuButton<String>(
                        tooltip: 'Account options',
                        onSelected: (_) => _forget(profile),
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'signout',
                            child: Text('Sign out on this device'),
                          ),
                        ],
                      ),
                onTap: _opening == null ? () => _connect(profile) : null,
              ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _opening == null ? () => _connect() : null,
              icon: const Icon(Icons.add),
              label: const Text('Connect Open WebUI'),
            ),
          ],
        ),
      ),
    ),
  );
}

class WebUiSignInPage extends StatefulWidget {
  const WebUiSignInPage({super.key, required this.accounts, this.profile});
  final WebUiAccounts accounts;
  final ServerProfile? profile;
  @override
  State<WebUiSignInPage> createState() => _WebUiSignInPageState();
}

class _WebUiSignInPageState extends State<WebUiSignInPage> {
  final _name = TextEditingController(),
      _url = TextEditingController(),
      _email = TextEditingController(),
      _password = TextEditingController(),
      _token = TextEditingController();
  final _headers = <(TextEditingController, TextEditingController)>[];
  bool _keyMode = false, _busy = false, _httpAcknowledged = false;
  String? _error;
  late final String _id = widget.profile?.id ?? 'webui-${const Uuid().v4()}';
  @override
  void initState() {
    super.initState();
    _name.text = widget.profile?.name ?? '';
    _url.text = widget.profile?.baseUrl ?? '';
    _httpAcknowledged = widget.profile?.insecureLanAcknowledged ?? false;
    for (final name in widget.profile?.headerNames ?? <String>[]) {
      _headers.add((
        TextEditingController(text: name),
        TextEditingController(),
      ));
    }
  }

  @override
  void dispose() {
    for (final field in [
      _name,
      _url,
      _email,
      _password,
      _token,
      ..._headers.expand((pair) => [pair.$1, pair.$2]),
    ]) {
      field.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final root = OpenWebUiClient.canonicalRoot(_url.text);
      if (root.scheme == 'http' &&
          (!insecureHttpHostAllowed(root.toString()) || !_httpAcknowledged)) {
        throw const WebUiException(
          'Use HTTPS, or acknowledge an allowed local-network HTTP connection.',
        );
      }
      final headers = {
        for (final pair in _headers)
          pair.$1.text.trim().toLowerCase(): pair.$2.text,
      };
      if (headers.length != _headers.length) {
        throw const WebUiException('Each gateway header needs a unique name.');
      }
      if (!_keyMode && (_email.text.trim().isEmpty || _password.text.isEmpty)) {
        throw const WebUiException(
          'Enter your server account email and password.',
        );
      }
      if (_keyMode && _token.text.trim().isEmpty && widget.profile == null) {
        throw const WebUiException(
          'Enter an API key with access to account identity and history.',
        );
      }
      final profile = ServerProfile(
        id: _id,
        name: _name.text.trim().isEmpty ? root.host : _name.text.trim(),
        protocol: ServerProtocol.openWebUi,
        baseUrl: root.toString(),
        authentication: ServerAuthentication.bearer,
        headerNames: headers.keys.toList(),
        acknowledgedInsecureOrigin: _httpAcknowledged ? root.origin : null,
      );
      final session = await widget.accounts.open(
        profile,
        email: _keyMode ? null : _email.text,
        password: _keyMode ? null : _password.text,
        token: _keyMode ? _token.text : null,
        headers: headers,
      );
      _password.clear();
      _token.clear();
      if (mounted) {
        Navigator.pop(context, session);
      } else {
        session.lock();
        session.client.close();
      }
    } on Object catch (failure) {
      if (mounted) {
        setState(
          () => _error = failure is WebUiException
              ? failure.message
              : failure is FormatException
              ? failure.message
              : 'Sign-in could not be completed. Check the server address and credentials.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Connect Open WebUI')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(
                labelText: 'Connection name',
                hintText: 'Home',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _url,
              enabled: !_busy && widget.profile == null,
              keyboardType: TextInputType.url,
              autocorrect: false,
              onChanged: (_) => setState(() => _httpAcknowledged = false),
              decoration: const InputDecoration(
                labelText: 'Server address',
                hintText: 'https://chat.example.com',
              ),
            ),
            if (_url.text.startsWith('http://'))
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: _httpAcknowledged,
                onChanged: _busy
                    ? null
                    : (value) =>
                          setState(() => _httpAcknowledged = value == true),
                title: const Text(
                  'Allow unencrypted access on this local network',
                ),
              ),
            const SizedBox(height: 24),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Sign in')),
                ButtonSegment(value: true, label: Text('API key')),
              ],
              selected: {_keyMode},
              onSelectionChanged: _busy
                  ? null
                  : (value) => setState(() => _keyMode = value.single),
            ),
            const SizedBox(height: 16),
            if (_keyMode)
              TextField(
                controller: _token,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'API key',
                  helperText: 'Requires access to identity and chat history.',
                ),
              )
            else ...[
              TextField(
                controller: _email,
                enabled: !_busy,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                autofillHints: const [AutofillHints.username],
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _password,
                enabled: !_busy,
                obscureText: true,
                autofillHints: const [AutofillHints.password],
                onSubmitted: (_) => _submit(),
                decoration: const InputDecoration(labelText: 'Password'),
              ),
            ],
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Gateway headers'),
              children: [
                for (final pair in _headers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: pair.$1,
                            enabled: !_busy,
                            decoration: const InputDecoration(
                              labelText: 'Header name',
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: pair.$2,
                            enabled: !_busy,
                            obscureText: true,
                            decoration: const InputDecoration(
                              labelText: 'Value',
                              hintText: 'Keep saved value',
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove header',
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _headers.remove(pair);
                                  pair.$1.dispose();
                                  pair.$2.dispose();
                                }),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                      ],
                    ),
                  ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => setState(
                          () => _headers.add((
                            TextEditingController(),
                            TextEditingController(),
                          )),
                        ),
                  icon: const Icon(Icons.add),
                  label: const Text('Add header'),
                ),
              ],
            ),
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'Your messages, context, and attachments are sent to this server. Its operator controls processing and retention. Your password is used for sign-in; only the issued token is stored securely.',
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: Text(_busy ? 'Connecting…' : 'Sign in and connect'),
            ),
            const SizedBox(height: Design.gutter),
            const Text(
              'If a restricted key supports only inference, use a separate OpenAI-compatible connection from Connections. Shared history requires the permissions above.',
            ),
          ],
        ),
      ),
    ),
  );
}
