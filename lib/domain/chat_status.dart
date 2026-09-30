/// Connection evidence for one saved server profile.
///
/// The status reflects the last actual probe or request result. It is not a
/// guarantee of continuous connectivity and is never refreshed by polling.
enum ConnectionStatus {
  /// The bootstrap profile of a fresh installation that the user has not set up.
  notConfigured('Not set up'),

  /// Saved locally; no probe or request has established reachability yet.
  saved('Saved'),

  /// A connection probe is in progress.
  checking('Checking'),

  /// The last probe or request to this server succeeded.
  ready('Ready'),

  /// The last probe or request could not reach the server or timed out.
  unavailable('Unavailable'),

  /// The server responded but rejected the request's authentication.
  authenticationRequired('Authentication required'),

  /// iOS local-network access was denied for this server.
  localNetworkDenied('Local network access needed');

  const ConnectionStatus(this.label);

  /// Short text label; status must never be conveyed by color alone.
  final String label;
}

/// Why network submission is or is not available for the visible chat.
///
/// Local draft editing is governed separately by `ChatController.canEditDraft`.
enum SubmitAvailability {
  /// No server connection has been configured yet.
  noConnection,

  /// The chat's saved server is not checked, checking, or unavailable.
  unavailable,

  /// The server is ready but no valid model is selected for this chat.
  noModel,

  /// A brief local mutation protects this chat's data.
  localMutation,

  /// A response is streaming; a follow-up can be queued.
  streaming,

  /// Queued follow-ups are paused and need explicit Resume.
  queuePaused,

  /// A message can be sent now.
  ready,
}

enum ChatFailureKind {
  transport,
  timeout,
  localNetworkDenied,
  authentication,
  missingModel,
  providerRejected,
  attachmentIncompatible,
  persistence,
  backgroundExpired,
  other,
}

/// A recovery action the UI can offer for a failure.
enum ChatRecoveryAction {
  retryConnection,
  editConnection,
  openSystemSettings,
  retry,
  resume,
  chooseModel,
  refreshModels,
  removeAttachment,
  retrySave,
}

/// A classified, redacted failure scoped to one chat, profile, or model.
final class ChatFailure {
  const ChatFailure({
    required this.kind,
    required this.message,
    this.actions = const <ChatRecoveryAction>[],
    this.profileId,
    this.messageId,
    this.detail,
  });

  final ChatFailureKind kind;

  /// Primary user-facing explanation. Never contains keys or auth headers.
  final String message;
  final List<ChatRecoveryAction> actions;

  /// The server profile involved, when known.
  final String? profileId;

  /// The assistant message the failure belongs to, when it is a request error.
  final String? messageId;

  /// Optional redacted technical detail suitable for an expandable view.
  final String? detail;

  @override
  bool operator ==(Object other) =>
      other is ChatFailure &&
      other.kind == kind &&
      other.message == message &&
      other.profileId == profileId &&
      other.messageId == messageId;

  @override
  int get hashCode => Object.hash(kind, message, profileId, messageId);

  @override
  String toString() => message;
}

enum ProfileSaveOutcome {
  /// The profile and any entered key were persisted locally.
  saved,

  /// The address of a profile with chats changes; call again with
  /// `confirmAddressChange: true` after the user confirms.
  confirmationRequired,

  /// The change is not allowed; [ProfileSaveResult.message] explains why.
  rejected,

  /// Local persistence failed; the previous configuration remains in place.
  persistenceFailed,
}

final class ProfileSaveResult {
  const ProfileSaveResult(this.outcome, {this.message, this.connection});

  final ProfileSaveOutcome outcome;
  final String? message;

  /// Result of the connection attempt for Save and connect; null otherwise.
  final ConnectionTestResult? connection;

  bool get saved => outcome == ProfileSaveOutcome.saved;
}

final class ConnectionTestResult {
  const ConnectionTestResult.success({required this.modelCount})
    : failure = null;
  const ConnectionTestResult.failure(ChatFailure this.failure) : modelCount = 0;

  final ChatFailure? failure;
  final int modelCount;

  bool get succeeded => failure == null;
}
