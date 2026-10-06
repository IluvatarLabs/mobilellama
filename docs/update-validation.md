# Update candidate: 1.4.0 (7)

This candidate implements the daily-chat, connection, shared-server, and
organization update. It is not yet a completed physical-device release or an
App Store submission. The app remains free. Direct Ollama and compatible API
connections remain available without an account.

## Behavior

- Shared light/dark styling, readable chat typography, a bounded text column,
  and a persistent history sidebar on sufficiently wide iPad layouts.
- Explicit API roots, independent profile credentials, bearer or `api-key`
  authentication, secure custom headers, API versions, and manual model IDs.
- Direct Chat Completions and stateless Responses conversations. Responses
  sends complete selected context with `store:false`, preserving replayable
  output separately from display text. A missing terminal event is incomplete.
- Bounded history windows, full-history search/export/context, retained answer
  versions, and explicit continuation from a selected version.
- iOS Share Extension staging into an App Group. The user manually opens the
  app and reviews the destination before Send. Partial imports retain their
  draft destination and item order through restart. Image paste is explicit;
  the app does not poll the clipboard.
- Local folders with inherited instructions and explicit per-chat overrides.
- Optional Open WebUI accounts with server-owned conversations, authenticated
  live events, reconciliation after uncertain delivery, account-scoped cached
  history/drafts/queues, files, knowledge, prompts, skills, configured tools,
  citations, and supported server image outputs. Selecting a resource does not
  prove a server supports or has executed it.
- Temporary sessions remain separate from ordinary history until explicit
  Save. Direct temporary attachments use disposable local storage. Open WebUI
  temporary chat is text-only, explicitly disables tool discovery/execution,
  requires an authenticated live session, and does not reconnect or replay
  after losing that session. Server model instructions and logging still apply.
- Bundled Mermaid rendering on iOS 17.4 and later, with source fallback on older
  systems or unsupported/malformed diagrams. Rendering uses bundled assets and
  a restrictive content policy.

## Data migration and interoperability

SQLite schema 13 stores immutable message nodes and an active conversation tip.
Migration preserves the existing linear history and converts retained recovery
checkpoints into versions. All branch-aware consumers use this graph: display,
context, search, backup, restore, folders, and synchronization.

Portable backup format 2 preserves branches and folders; version-1 imports
remain supported. Open WebUI exports are explicit inert local copies. Import
requires choosing an existing direct destination. Server credentials, operational
IDs, private source URLs, and executable tool records do not become local
conversation authority.

iCloud transitions within the existing container to the private `ChatsV2`
zone. Old-zone writes stop durably before new-format edits; the complete new
inventory and tombstones are read before publishing. The old `Chats` zone is
left intact as one-time migration input. Divergent old edits are retained as
recovered copies with a durable adoption ledger. Migration can remain pending
offline without blocking local chat.

Old app installations synchronize only with other old installations until
upgraded. There is no continuous bridge back to the old format and no supported
downgrade that flattens branches. iCloud opt-in is preserved. Remote account
caches and temporary sessions are excluded from direct-chat synchronization.

## Evidence recorded October 5–6, 2026

| Layer | Observed outcome | Limits |
| --- | --- | --- |
| Dart regression suite | 175 tests pass, including partial-share restart/order/rollback/discard, retained version recovery, and recovered shared-chat draft adoption | Does not establish native extension, physical performance, or CloudKit behavior |
| Direct live server | Ollama 0.32.14, qwen2.5:3b: native chat, compatible Chat Completions, and Responses each complete two turns and preserve stopped partial output; Responses executes tools and preserves tool-bearing history through export/import and another tool-bearing turn | One real inference server/model; web-result content is a fixed fixture. Additional live gateway checks pass for bearer auth at a prefixed root, `api-key` plus API version/custom header, and a manual model with discovery unavailable |
| Shared live server | Open WebUI 0.11.4: authenticated identity/socket, saved chat/context, regeneration and continuation from a retained version, drafts, folder move/delete-keeping-chat, file upload/processing/question, knowledge with an authenticated source, selected skill and configured tool execution with retained selections, export/local import, and temporary chat with exactly-once Save pass. Injected pre-dispatch loss causes no generation; lost acknowledgment reconciles with one dispatch; Stop retains partial output and pauses the queue | A disposable isolated instance using one model; configured image generation was unavailable; server image-output parsing/rendering has fixture coverage |
| Native simulator workflows | iPhone and iPad app UI exercises shared sign-in/chat, retained versions, folders, temporary sessions, and supported diagrams; real desktop-to-native continuity and parameterized prompt insertion pass; actual-app light/dark/large-text screenshots captured | The live prompt test uses Flutter synthetic keyboard input. No physical share-sheet or performance claim |
| Distribution | Signed 1.4.0 (7) archive and App Store IPA generated; host and extension signatures match their registered App Group | Final native installation/device checks remain pending; no upload or review submission |

Open WebUI is pinned to source commit
`8bd8b4fac5e059578ac0c74b3c18d11139f88b7d`; the tested official v0.11.4 image
digest is `sha256:9591b13f13843c7721c2b8eaf7382846c81b3ffe126526d1888d1fed50c6a33f`.
Those runtime identities were separately fetched from each running server and
the official image inspection on October 5; they are not inferred from test
names. Tests use Flutter 3.47.2 / Dart 3.13.2. The deployment minimum remains iOS 15.
Static analysis reports no errors or warnings and 80 informational lint findings.

Actual app captures from the simulator workflows: [iPad light](update-screenshots/shared-chat-light.png),
[iPad dark](update-screenshots/shared-chat-dark.png), and
[iPhone server prompt](update-screenshots/live-shared-native-prompt.png).
These document rendered app states, not physical-device acceptance.

Live resource acceptance found and corrected an inherited parent in a fresh
shared chat, early text-controller disposal on prompt dismissal, and automatic
server skill discovery in temporary mode. The shared-chat ID and complete draft
now change ownership in one SQLite transaction. The exact crash cut is supported
by transaction structure and recovery fixtures; it has not been force-killed on
a physical device.

## Additional acceptance completed October 6

- Installed the actual 1.4.0 (6) app, created a conversation, stopped answer,
  paused queue, unsent draft, and document using the app, then installed (7)
  over it. Schema 9 upgraded to 13 without changing any existing conversation,
  message, queue, or draft field. The migrated attachment reached a real model;
  retained answer versions, a folder, and the draft survived another restart.
- Force-terminated an active real Ollama stream: its exact partial answer and
  unsent draft survived. A controlled stream with a queued follow-up also
  recovered with the queue paused. Server request counts stayed unchanged until
  explicit Resume, which dispatched the queued message once.
- Exercised actual iOS simulator Safari and Photos share sheets, extension
  cancellation, cold launch, destination review, existing-draft merge, PDF
  extraction/question answering, native image paste, and explicit image Send.
  Import did not send a request. Temporary image files were present before
  force-termination and absent after relaunch, with no new saved conversation.
- Ran real Open WebUI accounts through password and API-key authentication at a
  prefixed root, 401 lock/recovery, account/cache/draft/queue/file isolation,
  denied-inventory retention, concurrent branches, explicit continuation,
  confirmed deletion, and sign-out. Sign-out purged populated local data while
  retaining server history and leaving the other account usable. The disposable
  server's roles, permissions, and model settings were restored afterward.
- Used the system's maximum accessibility text size in portrait and landscape,
  including the software keyboard. Ordinary and temporary Send delivered the
  complete draft; temporary Save preserved the result in ordinary history.
  Restored simulator text size, orientation, and clipboard synchronization.

These flows found and fixed three defects: a new shared request could be
reconciled before its first dispatch; Safari PDF shares did not offer the
extension when the source supplied mixed representations; and the chat header
reserved uncapped text height despite Flutter capping the actual title, clipping
large composer text above the landscape keyboard. Both timing and layout
regressions fail against the old implementation and pass with their corrections.
The edit-message sheet now describes retained versions accurately.

The final regression suite reports 175 passes. Static analysis has no errors or
warnings and 80 informational findings. The live account run was independently
reviewed against its source and recorded build/log hashes. Native screenshots,
SQLite snapshots, request logs, and signed-artifact verification are retained
with the release evidence; simulator results remain distinct from physical
hardware acceptance.

## Remaining acceptance before calling the update shipped

Jarvis and the available iPads were reported unavailable by Xcode's device tools
on October 6. The following required checks need connected physical devices:

- Final signed iPhone/iPad installation, share/paste, speech and permissions,
  VoiceOver, reduced motion/transparency, iPad split view, and actual background
  expiration/relaunch.
- Short/long mixed-content streaming while typing and scrolling in profile or
  release mode, with physical frame timings and detached-scroll behavior.
- Old/new app operation on two iCloud devices: divergent offline edits,
  upgrade/restart/repeat migration, deletion, folders and branches, and direct
  iCloud operation while using an Open WebUI account.
- Final device screenshots and the physical-device recording requested by App
  Review, followed by the App Store upload and review submission.

No physical-device pass, App Store upload, or review submission is claimed.
