import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../chat/chat_controller.dart';
import '../data/settings_store.dart';
import '../ui/design.dart';

/// Shown before chat content is first sent to a server.
const destinationDisclosure =
    'Messages, conversation context, and attachments are sent to this server. '
    'Its operator controls processing and retention.';

const _localhostHelp =
    'On an iPhone, localhost means this phone. Use your server’s LAN address '
    'or hostname.';

/// Opens the connection form directly.
///
/// With no [profile] it creates a new connection, or on a fresh installation
/// ([ChatController.isConfigured] is false) sets up the unconfigured bootstrap
/// profile with empty fields. Returns true only when Save and connect saved
/// the connection and it connected; the caller decides what follows (for
/// example model selection). Save alone, Cancel, and failures return false.
Future<bool> showConnectionForm(
  BuildContext context,
  ChatController controller, {
  ServerProfile? profile,
}) async {
  final connected = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) =>
          ConnectionFormPage(controller: controller, profile: profile),
    ),
  );
  return connected ?? false;
}

/// Shows the destination disclosure before the first Connect of a profile that
/// was saved without connecting. Returns true when the destination is (now)
/// acknowledged for the profile's protocol and canonical endpoint.
Future<bool> confirmServerDestination(
  BuildContext context,
  ChatController controller,
  ServerProfile profile,
) async {
  if (controller.isDestinationAcknowledged(profile)) return true;
  final accepted = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Connect to “${profile.name}”?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(destinationDisclosure),
          const SizedBox(height: Design.space3),
          SelectableText(
            profile.baseUrl,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Connect'),
        ),
      ],
    ),
  );
  if (accepted != true) return false;
  return controller.acknowledgeDestination(profile);
}

enum _Busy { save, connect, test }

final class _Notice {
  const _Notice(this.text, {this.error = false, this.failure});
  final String text;
  final bool error;
  final ChatFailure? failure;
}

class ConnectionFormPage extends StatefulWidget {
  const ConnectionFormPage({super.key, required this.controller, this.profile});

  final ChatController controller;

  /// The configured profile to edit; null creates or sets up a connection.
  final ServerProfile? profile;

  @override
  State<ConnectionFormPage> createState() => _ConnectionFormPageState();
}

class _ConnectionFormPageState extends State<ConnectionFormPage> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _key = TextEditingController();
  late final String _id;
  late final bool _editing;
  ServerProtocol _protocol = ServerProtocol.ollama;
  String? _acknowledgedOrigin;
  _Busy? _busy;
  _Notice? _notice;

  ChatController get _controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final profile = widget.profile;
    _editing = profile != null && profile.configured;
    _id =
        profile?.id ??
        (_controller.isConfigured
            ? 'profile-${DateTime.now().microsecondsSinceEpoch}'
            : _controller.activeProfileId);
    if (_editing) {
      _name.text = profile!.name;
      _url.text = profile.baseUrl;
      _protocol = profile.protocol;
      _acknowledgedOrigin = profile.acknowledgedInsecureOrigin;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  bool get _isHttp => Uri.tryParse(_url.text.trim())?.scheme == 'http';
  bool get _httpHostAllowed => !_isHttp || insecureHttpHostAllowed(_url.text);
  String? get _currentOrigin => normalizedServerOrigin(_url.text);
  bool get _httpAcknowledged =>
      _isHttp &&
      _currentOrigin != null &&
      _currentOrigin == _acknowledgedOrigin;
  bool get _canSubmit =>
      _busy == null &&
      !_controller.profileMutationBusy &&
      _url.text.trim().isNotEmpty &&
      _httpHostAllowed &&
      (!_isHttp || _httpAcknowledged);

  String get _endpoint {
    final raw = _url.text.trim();
    if (raw.isEmpty) return 'Enter a server URL';
    try {
      return SettingsStore.canonicalBaseUrl(raw);
    } on FormatException {
      return raw;
    }
  }

  bool get _savedKeyApplies {
    if (!_editing || _protocol != ServerProtocol.openAiCompatible) return false;
    try {
      return widget.profile!.protocol == ServerProtocol.openAiCompatible &&
          SettingsStore.canonicalBaseUrl(_url.text) ==
              widget.profile!.baseUrl &&
          _controller.hasServerApiKeyForProfile(_id);
    } on Object {
      return false;
    }
  }

  String? get _enteredKey =>
      _protocol == ServerProtocol.openAiCompatible &&
          _key.text.trim().isNotEmpty
      ? _key.text.trim()
      : null;

  ServerProfile? _buildProfile() {
    final url = _url.text.trim();
    final name = _name.text.trim().isNotEmpty
        ? _name.text.trim()
        : (Uri.tryParse(url)?.host.isNotEmpty ?? false)
        ? Uri.parse(url).host
        : 'Server';
    try {
      return ServerProfile(
        id: _id,
        name: name,
        protocol: _protocol,
        baseUrl: url,
        acknowledgedInsecureOrigin: _acknowledgedOrigin,
      );
    } on FormatException catch (error) {
      setState(() => _notice = _Notice('${error.message}.', error: true));
    } on ArgumentError catch (error) {
      setState(
        () => _notice = _Notice(
          '${error.message ?? 'Check the form'}.',
          error: true,
        ),
      );
    }
    return null;
  }

  Future<void> _submit({
    required bool connect,
    bool confirmAddressChange = false,
  }) async {
    FocusManager.instance.primaryFocus?.unfocus();
    final profile = _buildProfile();
    if (profile == null) return;
    setState(() {
      _busy = connect ? _Busy.connect : _Busy.save;
      _notice = null;
    });
    ProfileSaveResult result;
    try {
      result = connect
          ? await _controller.saveAndConnectServerProfile(
              profile,
              serverApiKey: _enteredKey,
              confirmAddressChange: confirmAddressChange,
              makeActive: true,
              preserveConversation: true,
            )
          : await _controller.saveServerProfile(
              profile,
              serverApiKey: _enteredKey,
              confirmAddressChange: confirmAddressChange,
            );
    } on Object catch (error) {
      result = ProfileSaveResult(
        ProfileSaveOutcome.persistenceFailed,
        message: 'The connection could not be saved: $error',
      );
    }
    if (!mounted) return;
    setState(() => _busy = null);
    switch (result.outcome) {
      case ProfileSaveOutcome.confirmationRequired:
        if (await _confirmAddressChange(result.message)) {
          await _submit(connect: connect, confirmAddressChange: true);
        }
      case ProfileSaveOutcome.rejected:
        setState(
          () => _notice = _Notice(
            result.message ?? 'This change is not allowed.',
            error: true,
          ),
        );
      case ProfileSaveOutcome.persistenceFailed:
        setState(
          () => _notice = _Notice(
            '${result.message ?? 'The connection could not be saved on this phone.'} '
            'Nothing was changed.',
            error: true,
          ),
        );
      case ProfileSaveOutcome.saved:
        final connection = result.connection;
        if (!connect) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(
                [
                  'Saved “${profile.name}”. Not connected yet.',
                  ?result.message,
                ].join(' '),
              ),
            ),
          );
          Navigator.pop(context, false);
        } else if (connection != null && connection.succeeded) {
          Navigator.pop(context, true);
        } else {
          final failure = connection?.failure;
          setState(
            () => _notice = _Notice(
              'Saved on this phone, but not connected. '
              '${failure?.message ?? 'The server could not be reached.'}',
              error: true,
              failure: failure,
            ),
          );
        }
    }
  }

  Future<void> _test() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final profile = _buildProfile();
    if (profile == null) return;
    setState(() {
      _busy = _Busy.test;
      _notice = null;
    });
    final result = await _controller.testConnection(
      profile,
      serverApiKey: _enteredKey,
    );
    if (!mounted) return;
    setState(() {
      _busy = null;
      _notice = result.succeeded
          ? _Notice(
              'Connection works. ${result.modelCount == 1 ? '1 model' : '${result.modelCount} models'} '
              'available. Test only; changes are not saved.',
            )
          : _Notice(
              '${result.failure!.message} Test only; changes are not saved.',
              error: true,
            );
    });
  }

  Future<bool> _confirmAddressChange(String? message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Update address?'),
        content: Text(
          '${message ?? 'Existing chats on “${widget.profile?.name ?? _name.text.trim()}” will use the new address.'} '
          'To keep them on the old address, create a new connection instead.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Update address'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Widget _busyLabel(_Busy which, String label) => _busy == which
      ? Semantics(
          label: label,
          child: const SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        )
      : Text(label);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final compatible = _protocol == ServerProtocol.openAiCompatible;
    final disabled = _busy != null;
    return Scaffold(
      backgroundColor: Design.panel(context),
      appBar: AppBar(
        backgroundColor: Design.panel(context),
        title: Text(_editing ? 'Edit connection' : 'Connect a server'),
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: <Widget>[
            Expanded(
              child: ListView(
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: const EdgeInsets.all(Design.gutter),
                children: <Widget>[
                  TextField(
                    controller: _name,
                    enabled: !disabled,
                    textCapitalization: TextCapitalization.words,
                    textInputAction: TextInputAction.next,
                    decoration: const InputDecoration(
                      labelText: 'Name',
                      hintText: 'Home',
                      border: _fieldBorder,
                    ),
                  ),
                  const SizedBox(height: Design.gutter),
                  Text('Connection type', style: theme.textTheme.labelLarge),
                  const SizedBox(height: Design.space2),
                  SegmentedButton<ServerProtocol>(
                    segments: const <ButtonSegment<ServerProtocol>>[
                      ButtonSegment(
                        value: ServerProtocol.ollama,
                        label: Text('Ollama'),
                      ),
                      ButtonSegment(
                        value: ServerProtocol.openAiCompatible,
                        label: Text('OpenAI-compatible'),
                      ),
                    ],
                    selected: <ServerProtocol>{_protocol},
                    showSelectedIcon: false,
                    expandedInsets: EdgeInsets.zero,
                    onSelectionChanged: disabled
                        ? null
                        : (value) => setState(() => _protocol = value.single),
                  ),
                  const SizedBox(height: Design.gutter),
                  TextField(
                    controller: _url,
                    enabled: !disabled,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      labelText: 'Server URL',
                      hintText: compatible
                          ? 'https://example.com/v1'
                          : 'http://192.168.1.20:11434',
                      helperText: compatible
                          ? 'Include the /v1 path where the server provides its API.'
                          : 'Ollama uses port 11434 unless you changed it.',
                      helperMaxLines: 3,
                      border: _fieldBorder,
                    ),
                  ),
                  const SizedBox(height: Design.space2),
                  Text(
                    _localhostHelp,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  if (_isHttp && !_httpHostAllowed) ...<Widget>[
                    const SizedBox(height: Design.space3),
                    Text(
                      'Public or ambiguous HTTP hosts are blocked. Use HTTPS, '
                      'localhost, a .local hostname, or a private IP address.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ] else if (_isHttp)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _httpAcknowledged,
                      onChanged: disabled
                          ? null
                          : (value) => setState(
                              () => _acknowledgedOrigin = value == true
                                  ? _currentOrigin
                                  : null,
                            ),
                      title: const Text(
                        'I understand HTTP traffic is unencrypted.',
                      ),
                      controlAffinity: ListTileControlAffinity.leading,
                    ),
                  if (compatible) ...<Widget>[
                    const SizedBox(height: Design.gutter),
                    TextField(
                      controller: _key,
                      enabled: !disabled,
                      obscureText: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: InputDecoration(
                        labelText: 'API key (optional)',
                        hintText: _savedKeyApplies ? '••••••••' : null,
                        floatingLabelBehavior: _savedKeyApplies
                            ? FloatingLabelBehavior.always
                            : FloatingLabelBehavior.auto,
                        helperText: _savedKeyApplies
                            ? 'A key is saved for this address. Leave blank to keep it.'
                            : 'Sent only to this server. Web search uses a separate Ollama cloud key.',
                        helperMaxLines: 3,
                        border: _fieldBorder,
                      ),
                    ),
                  ],
                  const SizedBox(height: Design.gutter),
                  _Disclosure(endpoint: _endpoint),
                  if (_notice case final notice?) ...<Widget>[
                    const SizedBox(height: Design.gutter),
                    _NoticeView(
                      notice: notice,
                      onRetry: notice.failure == null || disabled
                          ? null
                          : () => _submit(connect: true),
                    ),
                  ],
                ],
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: Design.line(context))),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  Design.gutter,
                  Design.space3,
                  Design.gutter,
                  Design.space3,
                ),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: Design.space2,
                  runSpacing: Design.space2,
                  children: <Widget>[
                    if (_editing)
                      TextButton(
                        style: TextButton.styleFrom(
                          minimumSize: const Size(Design.target, Design.target),
                        ),
                        onPressed: _canSubmit ? _test : null,
                        child: _busyLabel(_Busy.test, 'Test connection'),
                      ),
                    OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(Design.target, Design.target),
                      ),
                      onPressed: _canSubmit
                          ? () => _submit(connect: false)
                          : null,
                      child: _busyLabel(_Busy.save, 'Save'),
                    ),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(Design.target, Design.target),
                      ),
                      onPressed: _canSubmit
                          ? () => _submit(connect: true)
                          : null,
                      child: _busyLabel(_Busy.connect, 'Save and connect'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

const _fieldBorder = OutlineInputBorder(
  borderRadius: BorderRadius.all(Radius.circular(Design.radiusSmall)),
);

class _Disclosure extends StatelessWidget {
  const _Disclosure({required this.endpoint});
  final String endpoint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: Design.group(context),
      borderRadius: BorderRadius.circular(Design.radiusMedium),
      child: Padding(
        padding: const EdgeInsets.all(Design.space3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(destinationDisclosure, style: theme.textTheme.bodyMedium),
            const SizedBox(height: Design.space2),
            Text(
              endpoint,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NoticeView extends StatelessWidget {
  const _NoticeView({required this.notice, required this.onRetry});
  final _Notice notice;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final openSettings =
        notice.failure?.actions.contains(
          ChatRecoveryAction.openSystemSettings,
        ) ??
        false;
    return Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            notice.text,
            style: TextStyle(color: notice.error ? colors.error : null),
          ),
          if (notice.failure != null)
            Wrap(
              spacing: Design.space2,
              children: <Widget>[
                TextButton(
                  style: TextButton.styleFrom(
                    minimumSize: const Size(Design.target, Design.target),
                  ),
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
                if (openSettings)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(Design.target, Design.target),
                    ),
                    onPressed: () => launchUrl(Uri.parse('app-settings:')),
                    child: const Text('Open Settings'),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
