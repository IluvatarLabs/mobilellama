# MobileLlama iOS polish engineering specification

Implement the changes in this document to finish MobileLlama as a polished iOS chat client for a user's own Ollama or OpenAI-compatible server. The work concerns connection setup, everyday chat interactions, failure recovery, visual consistency, accessibility, and reliable operation of the existing features. This is an implementation handoff, with required behavior and acceptance criteria. It is not a new product roadmap.

Prepared on September 30, 2026 against commit `bbcdf1e0a1c5de86994f6151ba681dd3dd276b01`, app version `1.3.0+5`. Verified checkout: `/Users/yuanz/Documents/GitHub/mobilellama`. Recheck the checkout and relevant implementation before changing it; source locations identify the audited baseline, not immutable line numbers.

## User requirements and authority

The owner's requirements are:

> Give this project a fresh pass with fresh eyes, especially from a (1) feature completeness and (2) UX perspective. What are friction points, annoyances, basic conventions every chat app has, etc that are missing or need changing. Make sure to consider and full understand the actual purpose of this app and not just invent things that we don't need or don't care about.

> We want to make this beautiful, polished, bug-free, and ready to submit for free to the iOS app store.

> We have a membership. Not an issue. Focus on the engineering, not the bullshit. Write up the complete spec and I'll hand off to a developer agent.

The handoff author has specified the work, not implemented it. The receiving developer should execute the specification when the owner assigns it. Membership, pricing administration, account enrollment, marketing, and App Store Connect form entry are excluded. Do not submit or publish a build without the owner's separate instruction.

Before action, read `/Users/yuanz/.codex/AGENTS.md`, this specification, and any applicable repository `AGENTS.md` or `CLAUDE.md`. A Claude Code recipient must also read its actual global instructions at `~/.claude/CLAUDE.md` if present. There was no repository rules file or Multica declaration at the audited baseline. Check again rather than assuming that remains true. Do not delegate or fork unless the owner authorizes it. If delegation is authorized, partition implementation by file ownership and follow the governing rules for independent verification.

Apply this convention-first kernel verbatim:

Before inventing a custom method, find the current
established practice, and prefer the smallest standard component, pattern,
tool, or workflow that satisfies the explicit contract. If it fails, change
the component before adding custom complexity. Never add engineering solely to
mitigate problems introduced by optional complexity; remove that complexity
instead. Tests follow the same rule: prefer functional proof of the real workflow; a test
earns its place only by observing a material consequence of a reachable failure
for a named consumer; refusal branches and a library's own behavior are not
consequences; cases sharing one risk, seam, and oracle are one test; a vacuous
test is deleted, never rewritten or satisfied with a fix. Deviate from
convention only when standard options demonstrably fail a named requirement,
and record that evidence.

## Product contract

MobileLlama is a free, open-source mobile client. Models run on the server selected by the user, not inside this app. It serves people who want to use models on a Mac, home server, or hosted compatible API from their phone. iOS is the primary platform.

The core journey is: configure a connection, choose a model, chat, and return to saved work. A server going offline should prevent network operations, not prevent reading history or writing a draft. The destination of a request must be clear. Local chat content must survive ordinary navigation, interruptions, and failed retries.

Keep these existing capabilities working:

- Multiple named server profiles and model selection, including OpenAI-compatible metadata and explicit capability overrides.
- Streaming responses, Stop, retry, edit and regenerate, and follow-up queues with edit, reorder, remove, pause, and resume.
- Saved drafts per chat and per new-chat profile, images and document attachments, local history, global search, find in chat, rename, pin, archive, and delete with the existing safeguards.
- Markdown, syntax-highlighted code, code copying, math, sharing, portable backups and import.
- Dictation into an editable draft, read-aloud, per-chat settings, reusable presets, defaults, light and dark appearance.
- Optional web search through Ollama cloud services and optional iCloud chat sync, with their actual disclosure and configuration requirements.

Do not add accounts, subscriptions, payments, social features, a hosted inference service, a model marketplace, branching conversation navigation, automatic offline delivery, OCR, RAG, full voice conversations, feedback ratings without a consumer, or a notification service. Do not rewrite Flutter, the transports, SQLite, or the design system. Do not turn this work into an Android release or a general dependency modernization project.

## Required changes and order

All requirements below are part of this handoff. Priority determines implementation order, not optional scope.

| ID | Priority | Outcome |
| --- | --- | --- |
| ML 01 | P0 | Composer and critical controls work with the keyboard, large text, and short layouts. |
| ML 02 | P0 | History and drafts remain usable without a reachable server. |
| ML 03 | P0 | Edit, regenerate, and retry preserve a recoverable prior conversation. |
| ML 04 | P1 | First connection is direct and accurately represents configured state. |
| ML 05 | P1 | Saved connections can be managed offline and their addresses updated safely. |
| ML 06 | P1 | Model selection stays responsive while metadata loads or fails. |
| ML 07 | P1 | The destination and recovery action are clear when a request fails. |
| ML 08 | P1 | Existing screens and message actions have a consistent, accessible finish. |
| ML 09 | P1 | The actual iOS release configuration passes the defined engineering checks. |

Implement local state and persistence changes before dependent UI changes. Finish with the release validation matrix, not with a claim based only on compilation.

## ML 01 Adaptive composer and keyboard layout

### Problem and source

The composer uses a multiline `TextField` with `maxLines: 6` in a row of fixed-size controls. The chat body places the queue, attachment previews, and composer below an expanded transcript. These lower sections can collectively exceed the space left by the keyboard, especially in landscape with accessibility text sizes.

Primary locations: [composer.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/composer.dart), [chat_screen.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_screen.dart), [queue_panel.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/queue_panel.dart), [design.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/ui/design.dart).

### Required behavior

1. Bound the composer using the space actually available after keyboard and safe-area insets. The field grows while space permits, then scrolls internally. Input length must not be truncated to make the layout fit.
2. Keep Send reachable when available and Stop reachable throughout a response. They must remain above the keyboard and have at least a 44 by 44 logical-point hit target. While streaming, preserve both Stop and Queue when a draft can be queued.
3. Preserve system text scaling. Do not solve overflow by globally clamping Dynamic Type, shrinking body text, disabling landscape, hiding the keyboard, or making the entire chat scroll to reach Send.
4. Bound queue and attachment previews independently. In a short viewport, collapse them to summaries such as `2 queued` or `3 attachments`, with a reachable action opening the existing detail surface. Removing an attachment or editing a queue entry must remain possible.
5. Under severe height constraints, prioritize a usable editor and its primary actions. Secondary chrome and previews may collapse; the transcript need not remain visible while editing in the shortest landscape layout. Use a standard expanded editing surface if the inline layout cannot fit. Retain an obvious way back to the chat and its destination information.
6. Under severe width constraints, secondary actions may move into a conventional menu. Dictation may move from its separate button into that menu, but must remain discoverable. Do not put Stop or the available Send/Queue action behind a menu.
7. Rotation, keyboard dismissal, and text-size changes preserve draft text, selection, attachments, queue contents, and scroll position as far as the existing scroll behavior permits. Avoid focus churn or recreating the editing controller on every rebuild.
8. Forms, edit-message sheets, find-in-chat, queue editing, and connection editing must use the same keyboard and safe-area discipline. A confirmation button cannot become unreachable below the keyboard.

Use ordinary Flutter constraints, safe areas, and a scrollable text field. Flutter documents that a multiline field can grow within parent constraints and then scroll; `Scaffold` can resize its body around the keyboard. Do not introduce a custom keyboard geometry system. [TextField sizing](https://api.flutter.dev/flutter/material/TextField/maxLines.html), [Scaffold keyboard resizing](https://api.flutter.dev/flutter/material/Scaffold/resizeToAvoidBottomInset.html).

### Layout intent

Normal chat, schematic rather than fixed pixel geometry:

```text
+------------------------------------------------+
| Chats      model name v        New chat   More |
|            Home server · Ready                 |
+------------------------------------------------+
|                                                |
|                  transcript                    |
|                                                |
|            [Jump to latest when needed]         |
+------------------------------------------------+
| Queue summary or bounded queue                 |
| Bounded attachment previews                    |
| [+] [ draft grows, then scrolls ] [Mic] [Send]  |
+------------------------------------------------+
| keyboard / bottom safe area                    |
+------------------------------------------------+
```

Short layout while editing:

```text
+------------------------------------------------+
| Compact destination and navigation             |
| [2 queued] [3 attachments]                      |
| [ bounded, internally scrolling draft        ] |
| [+ / secondary actions]          [Stop] [Queue] |
+------------------------------------------------+
| keyboard                                       |
+------------------------------------------------+
```

Do not reserve blank space for absent queues or attachments. Allow labels and sheets to grow at large text sizes.

### Acceptance

- On a small supported iPhone and a current iPhone simulator, test portrait and both landscape directions with keyboard open, normal text, accessibility extra large, and the largest available accessibility text setting.
- Exercise a long multiline draft, multiple images, a document, and multiple queued follow-ups. No overflow exception, clipped primary control, overlapping text, or action covered by the keyboard is acceptable.
- At large text sizes, the user can enter and select text, remove an attachment, open the queue, and tap Send/Stop/Queue without first dismissing the keyboard.
- Repeat the keyboard checks on the connection form and edit-message form. A real tap must reach the control; merely finding a widget is insufficient.

## ML 02 Offline history and editable drafts

### Problem and source

`ChatComposer.enabled` derives from `canQueueOrSend`, which requires `conversationConnected` and a selected model. `openConversation` holds a conversation mutation lock while probing the server. These couple local work to network availability. The persisted draft mechanism already exists and should be reused.

Primary locations: [chat_controller.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_controller.dart), [chat_screen.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_screen.dart), [composer.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/composer.dart), [conversation_store.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/data/conversation_store.dart).

### Required behavior

1. Separate local editing permission from network submission permission. A saved profile with an unreachable server, a missing model, or a failed probe must not disable text entry, selection, copying, draft persistence, or removal of draft attachments.
2. Local photo/document selection and dictation depend on their actual local operation and permission requirements, not on server reachability. Preserve attachments even if the model's capability is unknown. Validate whether they can be sent when submission becomes possible; never silently drop them.
3. Read an existing chat and its draft from local storage, release the local mutation lock, and render it before awaiting a network probe. The user must be able to move to another chat while an earlier probe is pending.
4. Use captured chat/profile scope for async results. A late probe, file picker, document extraction, or dictation result must not change a different visible chat's destination or draft. Reuse the existing draft-scope mechanism and controller lifecycle checks.
5. Preserve the existing scopes: a conversation's ID for its draft and the existing new-chat scope for each profile. Profile navigation must not merge drafts. Do not create a persisted empty conversation solely because the user typed into a new-chat draft.
6. A failed Send preserves the stored user message and any useful partial answer under the existing semantics. An unsent follow-up draft remains intact. A persistence failure must remain visible and must not be disguised as a network failure.
7. Reconnect, app foregrounding, or relaunch must not send a plain draft or restart a paused queue. An active response and an already authorized, unpaused queue retain their existing lifecycle behavior. A stopped or failed queue requires explicit Resume; a plain offline draft stays a draft.
8. Keep genuine local mutation locks narrowly scoped around operations that replace or delete the draft/transcript. Do not remove locking around destructive mutations to make the UI seem responsive.

### Interaction state contract

| State | Local draft and history | Network action |
| --- | --- | --- |
| No connection configured | Explain setup; a local text draft may be retained. | Connect a server. No chat request. |
| Saved connection, not checked or unavailable | Read and edit normally; preserve scoped attachments. | Connect/Retry connection. Send unavailable with a reason. |
| Ready connection, no valid selected model | Read and edit normally. | Choose model. No silent substitution for an existing chat. |
| Ready and compatible draft | Read and edit normally. | Send. |
| Response streaming | Read history and compose a follow-up under existing queue rules. | Stop and Queue. |
| Queue paused after Stop/failure | Edit draft and queue normally unless a local mutation is in progress. | Explicit Resume when ready. |
| Atomic local mutation in progress | Briefly protect the affected data. Other independent views stay usable. | No conflicting submission for that chat. |

### Acceptance

Use two profiles and at least two chats, each with a different draft. Stop the fixture server, relaunch the app, open both chats, and edit each draft. Restart again and verify the exact text and attachment references remain in the correct scope. History search, copying, and archive access must work offline.

Then restore the server. Before the user taps Send or explicitly resumes a paused queue, the fixture must record zero newly transmitted chat requests. Send the chosen draft and verify the request contains the expected chat context, attachments, profile, and model exactly once.

## ML 03 Safe edit regenerate and retry

### Problem and source

`_reviseConversation` calls `replaceConversationTail` before starting the replacement response, then deletes unused media. Latest-response regeneration has no later-message warning. A failure can therefore remove the previous answer before a usable replacement exists. The same preservation principle applies to retrying a useful interrupted response.

Primary locations: [chat_controller.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_controller.dart), [transcript.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/transcript.dart), [conversation_store.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/data/conversation_store.dart), [message.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/domain/message.dart), [chat_backup.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/data/chat_backup.dart).

### Chosen recovery contract

Keep one durable recovery checkpoint per conversation for the most recent edit, regenerate, or retry that replaces meaningful stored content. This is one-level recovery, not branches or a version browser. It survives navigation and app termination. It stays available after success, failure, or Stop until the next independent transcript change in that chat.

The UI action is `Restore previous conversation`. After a revision begins, show a persistent, compact recovery affordance near its result, and make the action reachable from Chat actions. A short toast alone is insufficient. Explain the boundary once in that surface: `Available until you send or revise another message.`

### Persistence requirements

1. Store the prior tail and perform the canonical tail replacement in the same SQLite transaction. If saving the checkpoint fails, leave the original conversation unchanged and do not start the replacement request.
2. Store complete message data, not rendered text: IDs, ordering, roles, status, content, reasoning, provider transcript, images, documents and extracted text, tool calls/results and their IDs, and timestamps. Reuse existing serialization and attachment-reference conventions where they satisfy this contract.
3. Add the smallest schema migration needed for one checkpoint per chat, with a foreign key that cascades on conversation deletion. The audited store schema is version 8. Do not repurpose portable backup files as the transaction mechanism or copy attachment bytes into an unbounded JSON blob.
4. Protect all attachment references retained by a checkpoint from garbage collection, including app-start cleanup, draft cleanup, revision cleanup, and sync replacement cleanup. Replacing or consuming a checkpoint releases only references no longer used by messages, drafts, queues, or another retained record.
5. Own streaming writes belong to the revision and do not invalidate its checkpoint. A committed new user turn, a subsequent revision, or incoming sync replacement does invalidate or replace it atomically. Failed independent mutations must not discard recovery. Queue editing and pin/archive/rename alone do not invalidate it.
6. Incoming sync replacement must not leave an old checkpoint that could overwrite newer canonical content. A conflict copy remains a separate chat under the existing sync behavior. Apply checkpoint removal inside the same local transaction that installs the replacement.
7. Recovery data is local only. Existing backups, readable exports, shares, model requests, and iCloud snapshots continue to contain only the canonical conversation, never hidden prior content. Do not change the backup format merely to add undo. Restoring a checkpoint changes canonical history and therefore follows the existing export and sync path.
8. Deleting a chat deletes its recovery checkpoint. Importing a portable backup does not invent a checkpoint or resurrect hidden content.

### Revision and restore behavior

- Latest-response regeneration needs no extra confirmation merely to start. It must preserve the previous response through the checkpoint.
- Editing a user message or regenerating an older answer still warns once that later messages will be replaced. The warning must mention recovery and retain Cancel. Do not add repetitive confirmations to ordinary retry.
- If a replacement fails before output, leave the failure visible and make Restore available. If it produces useful partial output or the user taps Stop, keep that partial output visible and retain Restore. Do not silently overwrite a partial replacement with the old answer.
- Restoration is a local operation and works offline. If its revision is still running, require the user to stop that response first through the existing Stop operation. Cancel/finish pending writes before restoration; a late chunk cannot repopulate the replaced tail.
- Restore atomically replaces the revision tail with the checkpoint, preserves conversation ID, server profile, pins, archive state, current explicit name, and the separately scoped draft/queue. Recompute an automatically derived title from the restored first user turn. Do not revert independently edited chat settings or names as a side effect.
- Restore consumes the checkpoint. There is no redo or branch selector in this scope. A new revision replaces the previous checkpoint with a snapshot of the then-current tail.
- For retry of an empty failed placeholder, reuse existing retry behavior without creating a pointless empty recovery record. Preserve the associated user turn and attachments. For retry of useful partial content, create recovery before replacement.
- While a queued follow-up remains pending, preserve the existing restrictions on revising prior history. Do not introduce a second system that reconciles queue entries with rewritten branches.

### Acceptance

Create a chat containing a normal answer, an attached image/document, and tool or reasoning data supported by the fixture. Regenerate and force a transport failure; restore offline and verify the original tail and attachment bytes. Repeat by editing an earlier user message that has later turns, terminate the app during the replacement, relaunch, and restore.

Verify successful regeneration also permits restore until a subsequent committed turn. Verify a subsequent turn invalidates recovery without deleting live attachments. Export and sync the canonical chat and confirm hidden checkpoint content is absent. Delete the chat and confirm its checkpoint and now-unreferenced media are removed. These are outcome checks at the store/controller seam, not separate tests of every SQL refusal branch.

## ML 04 Direct first connection

### Problem and source

Fresh settings synthesize a `Default` profile using `http://localhost:11434`. Connect opens server management rather than a direct setup form, and the profile can appear saved before the user configured it. The README explains the client/server requirement and phone meaning of localhost, but the initial in-app journey does not.

Primary locations: [settings_store.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/data/settings_store.dart), [settings_sheet.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/settings/settings_sheet.dart), [chat_screen.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_screen.dart), [README.md](/Users/yuanz/Documents/GitHub/mobilellama/README.md).

### Required journey

```text
Fresh launch
    |
    v
Purpose explained + Connect a server
    |
    v
Connection form
  Name
  Connection type: Ollama / OpenAI-compatible
  Server URL
  API key when applicable
  HTTP acknowledgement when applicable
  Save / Save and connect
    |
    +-- Save without reachability --> Saved, not connected
    |
    +-- Connect fails --> Keep fields + actionable error + Retry
    |
    +-- Connect succeeds --> Choose model --> Ready to chat
```

1. Initial copy must state the purpose in plain language, for example: `Chat with models on your own server.` Supporting text: `Connect Ollama or an OpenAI-compatible API. Models run on that server.` Use the existing llama mark.
2. `Connect a server` opens the connection form directly. Do not make a first-time user select or edit a fake saved profile. No walkthrough carousel, account screen, or multi-page wizard is needed.
3. A new form starts with an empty URL and a descriptive placeholder. Use `http://192.168.1.20:11434` as an Ollama example and `https://example.com/v1` as a compatible example. These are examples, never assumed reachable endpoints.
4. Include short inline help: `On an iPhone, localhost means this phone. Use your server's LAN address or hostname.` Preserve valid localhost support for deliberate simulator/local use; do not reject it universally.
5. Label the choice `Connection type`, with `Ollama` and `OpenAI-compatible`. Explain `/v1` beside the compatible URL field. Keep the optional key secure and distinguish it from the separate Ollama cloud web-search key.
6. Request local-network permission only when attempting a relevant local connection. Camera, photos, microphone, and speech permissions remain tied to their features, not startup.
7. On successful Save and connect, continue to model selection if no valid model is configured. After selection, return to chat with the destination visible. Avoid making the user navigate back through settings after successful setup.
8. An empty model list is a usable state: say that the server is reachable but has no available models, offer Refresh and the existing model-management entry where supported, and keep the local draft. Do not manufacture a selectable default model.

### Migration requirement

Add an explicit configured/unconfigured distinction for the bootstrap profile, using the existing settings persistence. A fresh installation must remain unconfigured until the user saves a valid form. Existing profiles, chats, drafts, keys, capability overrides, and defaults must retain their IDs and data.

Do not infer that an existing profile is invalid simply because its name is `Default`, its URL is localhost, or it has not recently connected. Prior stored profile/legacy configuration and conversation references are migration evidence. Resolve ambiguity by preserving data and configuration, not by resetting an installation or forcing existing users through setup again.

### Acceptance

With clean app data, the first button opens an empty connection form in one tap. A reachable fixture connects and reaches model selection/chat without visiting profile administration. Failed setup leaves every entered field intact. A saved offline profile remains clearly saved but unavailable. An upgrade fixture containing the legacy default profile, chats, and secrets preserves them and does not misclassify it as a fresh install.

## ML 05 Offline connection management and safe address changes

### Problem and source

`upsertServerProfile` probes before persisting, `switchServerProfile` probes before selecting, and an identity change is refused whenever the profile has chats. A user's server changing its LAN address therefore makes existing chats difficult to continue. Conversations already reference a stable profile ID, which is the appropriate local identity to preserve.

Primary locations: [chat_controller.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_controller.dart), [settings_store.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/data/settings_store.dart), [settings_sheet.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/settings/settings_sheet.dart), [app.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/app.dart) for the platform secure-storage adapter.

### Save and test contract

1. Separate syntax validation and local persistence from network validation. `Save` persists a valid profile without requiring a response. `Save and connect` saves and then attempts connection. Retain a separate `Test connection` action in an existing profile's editor; it must not silently save unsaved form changes.
2. A failed network test cannot roll back a successfully saved local configuration or show it as connected. A failed local save cannot show success. Errors distinguish these outcomes.
3. Selecting a saved profile for a new chat works offline. It switches the destination and restores that profile's draft immediately. Connectivity is checked separately. Existing chats remain bound to their own profile ID.
4. Test requests must not transmit a chat or attachments. They use only the existing version/model/capability APIs needed to verify the configured connection type.
5. A late result applies only if the profile's ID, protocol, and canonical endpoint still match the request. It cannot activate a different profile or overwrite a newer saved address.

### Address change contract

1. Allow a same-protocol URL change on a profile with chats while preserving the profile ID. Show one confirmation that names the profile and explains that its existing chats will use the new address. Offer Cancel and `Update address`. The user can instead create a separate profile through the existing New connection action.
2. Preserve chat IDs, content, attachment references, titles, pins, archives, drafts, defaults, per-chat settings, and capability overrides. Do not duplicate all chats or require deletion to change a LAN IP.
3. Keep the existing create-a-new-profile restriction for changing protocol on a profile with history. This work does not translate Ollama provider transcripts/options into another protocol.
4. Do not mutate a running request's captured configuration. Reject address changes while that profile has a running response or model-management operation, with a specific instruction to stop or finish it. Unrelated profiles are not locked. Pause queued work for the changed destination and require explicit Resume; never dispatch it to the new endpoint as a save side effect.
5. Invalidate the changed endpoint's model/capability and connection-state cache. Preserve the chat's stored model name; a missing model after reconnect requires an explicit choice. Never switch an existing chat to an arbitrary available model.

### Credential and transport invariants

- Server API keys are currently scoped to protocol plus canonical URL. Preserve that scope. Never silently copy a bearer key from the old address to a new destination. Require entry of the key for the new canonical endpoint, or visibly use a key already stored for that exact endpoint. A blank field only preserves a key whose endpoint still matches.
- Clear the old in-memory client/key binding when changing identity. A subsequent request must not reuse the old client's authorization header.
- Keep old secrets until the profile update succeeds, and remove them only if no profile still references that exact secret. Preserve the existing rollback discipline when secure storage and profile persistence fail at different stages. Do not claim cross-store atomicity that the stores do not provide.
- Reset HTTP acknowledgement when the origin changes. Preserve the existing private/local HTTP allowlist, blocked ambiguous/public HTTP behavior, URL credential/query/fragment rejection, `/v1` requirement, and TLS validation. Do not weaken these to make setup pass.
- Profile deletion retains the existing protections for chats, drafts, and the last profile. A broader destructive profile-delete feature is outside this spec.

### Acceptance

Create an authenticated compatible profile and chats at endpoint A, then update its address to endpoint B with the same protocol. Verify all local IDs/data remain, B receives no A credential, old-origin HTTP acknowledgement is not reused, and cached models are invalidated. Provide B's key, connect, and continue the existing chat. Test an offline Save and offline profile switch. Inject local persistence failure and verify the UI does not claim the update succeeded and the previously saved configuration/key remains usable.

## ML 06 Responsive model selection

### Problem and source

Opening the picker starts `loadModelCapabilities`, which sets global mutation/model-management flags, probes the profile, and requests uncached Ollama details sequentially for every model. The picker can be dismissed while this work continues to disable context changes and the composer. Picker errors also do not consistently expose the capability-loading error.

Primary locations: [model_sheet.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/model_sheet.dart), [chat_controller.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_controller.dart), [model_management_page.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/model_management_page.dart).

### Required behavior

1. Display the cached list immediately. Refresh the list separately and show a localized loading indicator. A fresh profile with no list shows a loading or failure state, not a permanently empty picker.
2. Choose a model without waiting for details for every other model. Load the selected model's details on demand; fill optional badges progressively. Do not launch an unbounded request fanout or a sequential full-inventory request on every picker open.
3. Background metadata work cannot set a global profile mutation lock or disable drafting, navigation, Send for an otherwise usable text chat, or unrelated model rows. A brief local persistence operation may protect the selected chat's settings.
4. Model selection and persistence apply to the intended chat/profile. Preserve existing restrictions while that chat is streaming or has queued work. Other chats and drafts remain usable under their existing run ownership.
5. Unknown capabilities remain unknown. Do not infer vision/tools/thinking from a model name. Preserve OpenAI-compatible declared metadata and explicit profile overrides. Attachment/tool/thinking controls use known capability information and explain unavailable states; metadata failure alone must not block basic text chat with a known model ID.
6. Preserve the existing server-specific default model behavior. An unavailable stored model is shown as unavailable and prompts the user to choose; selecting a model for defaults must not silently change an existing conversation.
7. Scope each metadata response to its profile and endpoint generation. Stale responses after switching, changing the address, or disposing the controller are ignored. Coalesce duplicate in-flight reads for the same model where the current mechanism permits; do not create a general cache framework.
8. Dismissal leaves no UI lock. Cancel picker-exclusive work when feasible with the existing HTTP ownership, or allow harmless completion into the correct cache; never let it change current selection or status for a newer context.
9. A list refresh failure shows a short explanation and Retry in the picker while keeping cached rows. A selected model detail failure is local to that model and recoverable. Do not swallow the error and leave the user waiting without explanation.
10. Existing download, delete, cancellation, and progress UI for model management must remain correct. Scope destructive management locks to the affected profile/operation; metadata refresh is not model management.

### Acceptance

Use a fixture with several models and hold a nonselected model's detail response open. Open and dismiss the picker, type a draft, navigate to another chat, and select a different cached model. These actions must finish before the held request is released. Release it after a profile switch/address change and verify it cannot change the new context. Fail list refresh and one detail request separately and verify usable cached rows, visible recovery, and preserved compatible capability overrides.

## ML 07 Destination and actionable failures

### Required header and connection state

1. Keep model selection in the chat header and add the actual conversation's server name plus connection status as secondary information. Use the conversation's profile, not an unrelated active profile. For a new chat, use its selected profile.
2. Suggested labels are `Saved`, `Checking`, `Ready`, `Unavailable`, and a specific attention state such as `Authentication required`. A successful probe/request establishes readiness; a transport failure invalidates it. An HTTP authentication or model error must not be mislabeled as the phone being offline.
3. Status is based on actual app evidence, not a guarantee of continuous connectivity. Do not add network polling or a made-up expiration interval. If showing the last successful check, label it as such. Requests remain the source of truth when the server disappears after a probe.
4. Use text as well as color. Long model and server names may truncate in compact chrome, but the full destination must be accessible through semantics and the model/chat detail surface. Let the header adapt rather than retaining a fixed height that clips scaled text.
5. Expose the conversation's title in Chat actions/details. Do not put title, model, URL, and every status in a crowded header.

Primary locations: [chat_screen.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_screen.dart), [chat_controller.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_controller.dart), [chat_actions.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/chat/chat_actions.dart), [ollama_client.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/ollama/ollama_client.dart), [openai_compatible_client.dart](/Users/yuanz/Documents/GitHub/mobilellama/lib/ollama/openai_compatible_client.dart).

### Failure contract

Preserve typed error information through the controller instead of relying on raw `toString()` for the primary message. Reuse existing exception types and add only the classification needed to drive these actions.

| Failure | User explanation and action | Data behavior |
| --- | --- | --- |
| Transport unavailable or timeout | Name the server; Retry connection and Edit connection. | Keep draft, user turn, useful partial output, and paused queue. |
| Local-network permission denied | Explain the relevant permission; Open iOS Settings when supported, then Retry. | No permission loop or lost form/draft. |
| Authentication rejected | Explain that this server rejected authentication; Edit connection/key. | Do not erase the saved key or forward it elsewhere. |
| Stored model missing | Name the missing model; Choose model and Refresh list. | No silent model replacement. |
| Provider/model rejects a request | Present the returned useful explanation with Retry or the relevant setting action. | Keep failed-turn context and attachments. |
| Attachment incompatible | Name the attachment/model issue; Remove attachment or Choose model. | No automatic dropping of attachment content. |
| Local draft/response persistence fails | Say that the content could not be saved; preserve the current in-memory content and provide a retry of the relevant save where feasible. | No false saved/success state or destructive tail revision. |
| iOS background time expires | Say the response was interrupted; allow the existing Retry/Resume path on return. | Persist useful output and leave queued work paused. |

Keep request errors near the affected message, with a compact banner only when a broader connection/setup action is needed. Avoid a wall of raw exception text at the top of the transcript. Details may be expandable/copyable, but must omit API keys, authorization headers, URL credentials, and unnecessary private chat content. Do not collapse all non-200 responses into `Offline` or guess that a firewall is the cause.

Retry is explicit and affects the intended chat. Dismissing an error dismisses its presentation, not the failed status or the preserved data. A late run/probe error from chat A must not overwrite chat B's error or header. Repeated failures must not stack identical banners.

### Acceptance

Use the same model name on two profiles and confirm the destination remains distinguishable when switching between their chats. After a successful connection, stop that server during a stream; the failed chat must stop advertising readiness and offer a usable recovery action. Separately return authentication rejection, missing model, timeout, and provider request rejection. Each must give the correct action without changing unrelated chats or losing content. Retry must be observable as one request to the intended endpoint.

## ML 08 Visual finish and ordinary chat conventions

### Design direction

Keep the existing llama branding, ink `#2A2E3A`, blue accent `#3B5BDB`, neutral surfaces, SVG controls, and light/dark themes in `Design`. Improve hierarchy, spacing, alignment, and consistent states. This is not a rebrand or a new component library.

1. Reuse the existing 16-point content gutter and established sheet components. Use a small, shared spacing scale for repeated gaps rather than adding a different magic value to every screen. Match radius, borders, labels, icon weight, and disabled/error presentation across chat, settings, forms, model picker, and queue surfaces.
2. Render welcome copy as real text in both appearances. The current light-mode `welcome.png` contains the welcome presentation; replace that use with the native text/icon composition already used for dark/large text. Decorative art stays excluded from semantics. Do not generate another bitmap containing text.
3. Prefer readable system typography and semantic theme styles. Preserve body readability and paragraph spacing, including Markdown. Use accent color for the primary action or selected state, not for every control. Measure contrast of text and useful controls in both appearances.
4. Settings should share the chat's quiet surfaces and hierarchy. Group existing settings by task: Connections, chat defaults/presets, appearance, web search, data/sync, and Help/About. Advanced generation settings stay accessible without dominating first connection.
5. Use `Web search` for the user-facing optional feature. Explain that it uses Ollama cloud services, and label its key accordingly. Keep `API key` in a connection form scoped to that connection. Avoid exposing internal controller/type names in ordinary copy.
6. Each loading/empty/failure state says what is happening and offers the relevant existing next action. No blank model list, permanently spinning button, misleading saved/connected label, or decorative placeholder that hides required setup.
7. Confirmations are reserved for destructive changes or moving existing chats to a changed destination. Do not add a confirmation before normal Send, copying, opening history, or other reversible navigation.

### Message and history actions

Use one consistent, visible `More` menu trigger per message, with at least a 44-point target. Long press may open the same menu but cannot be the only way to reach it. Preserve text selection and code-block copying.

| Message | Primary visible actions | Secondary menu |
| --- | --- | --- |
| User prompt | More | Copy message; Edit and resend when permitted. |
| Completed assistant answer | Copy response; More | Regenerate; Share; Read aloud/Stop reading when available. |
| Failed/interrupted answer | Retry when permitted; More | Copy useful content; Share; Read aloud when available; Restore previous conversation when applicable. |
| Streaming answer | Existing streaming status and composer Stop | Copy currently available text if already supported; no conflicting revision. |

Remove the permanent floating edit pencil on each user bubble and the dense always-visible assistant action row after moving those actions into the menu. While read-aloud is active, keep an obvious reachable Stop reading control. Show a brief accessible confirmation after copying; do not change the user's selection or scroll position. Whole-message copy must work for the user's own prompt, not only for responses or selected text.

History rows retain their title, profile context, pin/archive/running indicators, and search behavior. Give row actions a visible menu entry using the same convention; long press remains an optional shortcut. Do not add folders, tagging, multi-select management, or new sorting systems. Keep the existing jump-to-latest behavior: streaming must not force the user back to the bottom while reading earlier content.

### Help About and privacy information

Add a small Help/About area in Settings using standard navigation:

- App name and version/build read from the actual installed build metadata, not a hardcoded string.
- Offline setup help covering the server prerequisite, LAN address/localhost distinction, `/v1`, optional keys, and the existing connection types. Reuse the accurate README guidance in user-facing language.
- `Report a problem` opening the repository's existing [issue page](https://github.com/IluvatarLabs/mobilellama/issues). Do not automatically upload logs, keys, or chat content.
- Open-source licenses through Flutter's standard license surface and the repository's existing license.
- An in-app privacy information screen that accurately explains local chat/draft/attachment storage, secure credential storage, transmission of chat context and attachments to the selected server, separate optional Ollama web-search transmission, optional iCloud sync, and system speech permissions/services. Verify the actual flow before writing these statements. Never assert `everything stays on device` or `no data is collected` on behalf of arbitrary user-selected providers.
- A Privacy policy link using the owner's release URL. If that URL is unavailable, identify it as a specific release configuration input while completing the in-app information and independent work. Do not invent or host a policy website.

The connection form must explain before use: `Messages, conversation context, and attachments are sent to this server. Its operator controls processing and retention.` Display the entered endpoint beside that explanation. The explicit Save and connect action acknowledges use of that destination. For a profile saved without connecting, show the same explanation at its first Connect action. Persist the acknowledgement against the canonical endpoint and protocol; a changed destination requires acknowledgement again. Do not add a recurring confirmation to Send.

Preserve the current explicit web-search disclosure before enabling it. Do not silently enable cloud search during setup or combine its acknowledgement with destination or HTTP consent.

### Accessibility contract

Give icon-only actions meaningful labels and appropriate enabled/selected/busy semantics. Ensure screen-reader order follows the visible flow. Do not announce every streamed token. Announce meaningful completion/failure or a status change without stealing focus from draft editing. Menus and dialogs return focus to their invoking control.

Use 44-point targets for the app's primary interactive controls and support large text by adapting layout. This matches Apple's platform guidance; color must not be the sole status cue. Verify contrast, VoiceOver labels, and actual navigation rather than assuming existing tooltips are sufficient. [Apple accessibility guidance](https://developer.apple.com/design/human-interface-guidelines/accessibility?changes=latest_maj_6_3&language=objc), [Apple touch and layout guidance](https://developer.apple.com/design/tips/).

### Acceptance

Capture the final welcome/setup, a normal conversation, failure/recovery, model selection, history/search, queue, and settings in light and dark appearance. Review normal and large text. No rasterized body copy, mismatched control styles, inaccessible menu-only gesture, clipped labels, or unnecessarily dense action rows should remain. With VoiceOver, complete connection, select a model, write/send, Stop, copy both roles, open history, and restore a revision. Verify real clipboard contents, not merely a snackbar.

## ML 09 Engineering release validation

### Configuration and native behavior

The current Xcode target includes iPhone and iPad and supports landscape; its deployment target is iOS 15. Validate those declared layouts and supported runtime paths rather than silently removing support to pass a check. The existing iCloud implementation includes newer-runtime guards; preserve them.

The simulator build used for ordinary development disables iCloud with `MOBILELLAMA_ICLOUD=false`. That build does not prove the normal release's CloudKit configuration. Use the owner's actual release configuration for the release check. If iCloud is enabled, validate its existing container/entitlements and optional opt-in flow on authorized physical devices. Do not remove iCloud or change its default availability solely to make a simulator pass. If a required device, container, or credential is unavailable, identify that exact unverified check while completing independent work.

Preserve the finite UIKit background-execution bridge. iOS may end background time; partial output and queues must recover honestly. Do not promise indefinite background inference or introduce unrelated background modes. [Apple background execution documentation](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

Verify purpose strings, native bridge registration, release entitlements, app icon and launch presentation, dependency privacy manifests, and any required-reason declarations actually needed by the shipped APIs in the archived build. Update the local-network purpose string to describe the user's chosen local server, including compatible servers, rather than implying all connections are Ollama. Do not declare a missing root manifest to be a defect without identifying an API that requires it. Do not add tracking, analytics, crash upload, or server-side infrastructure as part of validation.

### Existing proof to reuse

The repository already contains controller/widget/store/transport tests and iOS integration fixtures. Extend the nearest meaningful test instead of creating a parallel harness.

| Risk | Existing starting point |
| --- | --- |
| Draft, navigation, history, revisions | `test/chat/fundamentals_test.dart`, `qol_controller_test.dart`, `qol_presentation_test.dart`, `final_ux_test.dart`, `chat_presentation_test.dart` |
| Connection settings and migration | `test/data/settings_store_test.dart`, `test/chat/settings_phase2_test.dart` |
| Recovery, attachments, canonical export | `test/data/conversation_store_test.dart`, `chat_backup_test.dart`, `attachment_reference_relocation_test.dart` |
| Model loading and profile ownership | `test/chat/scoped_model_management_test.dart`, `model_management_page_test.dart` |
| Streaming, compatible metadata and failure | `test/ollama/ollama_client_test.dart`, `openai_compatible_client_test.dart`, `web_agent_test.dart` |
| Background time and sync | `test/chat/background_execution_test.dart`, `sync_test.dart` |
| Real native document extraction | `integration_test/document_reader_test.dart` |
| Streaming, queue, navigation, app switch | `integration_test/qol_workflow_test.dart`, `tool/qol_fixture_server.py` |

The QoL fixture supports separate `/home` and `/lab` destinations, controlled slow responses, queued turns, attachments, and request inspection. Extend it only for material failures needed by this spec, such as a held model-detail response or deterministic authentication rejection. Native document extraction must run on iOS; desktop PDF skips cannot substitute for that check.

### Required acceptance matrix

| Consumer outcome | Proof |
| --- | --- |
| A new user gets from launch to their first reply | Real first-run UI with clean app data, Ollama fixture, then a compatible endpoint. Confirm endpoint/model and request body. |
| An existing user keeps their installation's data | Upgrade populated pre-change settings/database; verify chats, drafts, pins, archives, defaults, keys, media, and backups. |
| A user can compose and read while offline | Two scoped drafts, unavailable server, relaunch and switch chats, reconnect with no unsolicited request, then explicit Send. |
| A user can safely change their server address | Same-profile endpoint change with history; verify destination, credential boundary, acknowledgement reset, and cache invalidation. |
| A user can select models without a frozen composer | Held/failed metadata requests while dismissing picker, navigating, typing, and choosing another cached model. |
| A user can recover a revision | Failed, interrupted, successful, and terminated replacement; offline restore including media/tool context; no hidden export/sync content. |
| A user can send or stop in constrained layouts | Small/current iPhone, portrait/landscape, keyboard, long draft, large text, queue and attachment summaries; actual taps and screenshots. |
| A user keeps control of scrolling and queued work | Long Markdown/code/math conversation, scroll away during streaming, explicit jump to latest, queue edit/reorder/remove, Stop and explicit Resume. |
| A user understands failures | Transport/auth/model/permission/provider failures with the right action; no data loss, stale destination, or credential exposure. |
| A user can use native inputs and outputs | Physical iPhone: camera/photos, PDF/TXT/Markdown, dictation and denied permission recovery, read-aloud Stop, clipboard and share-sheet anchoring. Also check iPad share/sheet layout. |
| A user can leave and return to the app | Short app switch during streaming, background expiration, relaunch, saved partial output and paused queue. No promise of unlimited background execution. |
| A user can use optional sync when shipped | Enabled release configuration on authorized physical devices: opt-in, no-account/error state, edit conflict preservation, deletion, and revision recovery invalidation. Disabled build stays usable without it. |
| A user can navigate with assistive technology | VoiceOver journey from setup through chat/history/recovery, labels/focus, text scaling, and appearance contrast. |
| The distributed binary matches the checked behavior | Build and install the actual Release configuration, exercise the core flow on a physical device, inspect the resulting archive and native configuration. |

Group tests by a shared risk, seam, and oracle. Do not add tests solely for an error string, disabled flag, getter, framework behavior, or implementation mirroring. Keep added tests proportional to changed code under the governing rules. A green existing suite is necessary regression evidence but does not prove a new outcome.

### Commands and execution notes

From the verified repository root:

```sh
flutter analyze
flutter test --reporter expanded
flutter build ios --simulator --dart-define=MOBILELLAMA_ICLOUD=false
flutter test integration_test/document_reader_test.dart \
  -d <isolated-ios-simulator-id> \
  --dart-define=MOBILELLAMA_ICLOUD=false \
  --reporter expanded
```

For the existing QoL workflow, run the fixture in a separate terminal:

```sh
python3 tool/qol_fixture_server.py --host 127.0.0.1 --port 18080
```

Then:

```sh
flutter test integration_test/qol_workflow_test.dart \
  -d <isolated-ios-simulator-id> \
  --dart-define=MOBILELLAMA_ICLOUD=false \
  --dart-define=QOL_FIXTURE_ORIGIN=http://127.0.0.1:18080 \
  --reporter expanded
```

The integration workflow emits `QOL_SLOW_RESPONSE_READY`; its current design expects external automation to press Simulator Home and return during the slow response. Perform that action through the authorized simulator control tool and record it. A run that never leaves the app does not establish app-switch behavior. Use a different isolated port if 18080 is occupied and pass the matching define. The simulator can reach the Mac loopback fixture; a physical phone requires a reachable LAN fixture/server address.

Record analyzer severity accurately, including informational diagnostics; do not call the analyzer completely clean merely because there are no errors. Fix diagnostics introduced by the change and actual warning/error defects; a project-wide stylistic lint rewrite is outside this spec. After integration tests, rebuild the normal app entry point before treating a simulator app bundle as the product build.

Use the documented release workflow and actual team/container configuration for the signed release build. Do not change bundle identity, destroy user data, publish, submit, or install local container VMs to obtain a green result. Clean up only the fixture processes and isolated simulators created for this work, and report what remains.

## Implementation boundaries

The controller is large, but its size is not authorization for an architectural rewrite. Separate permissions and ownership only where the named failures require it. Reuse `ConversationStore` transactions, existing run configuration capture, draft scopes, transport exception types, image/reference storage, and `Design` components. Introduce a small helper/type when it removes duplicated responsibility in these changes; do not introduce a general state-management, event-bus, retry, caching, or undo framework.

The following invariants are release-critical:

- One chat/profile owns each draft, queue, run, probe result, and recovery checkpoint. Changing the visible screen does not change the destination of captured work.
- Local persistence and network success are distinct. No network failure deletes local content; no failed local write appears saved.
- Revision checkpoint creation and canonical replacement are atomic; retained media cannot be collected prematurely.
- Secrets never enter history, backups, recovery records, logs, clipboard diagnostics, or arbitrary new endpoints.
- Model capability uncertainty cannot discard an attachment or silently change the selected model.
- Background interruption leaves an honest status, useful saved output, and explicitly resumable work.

STOP and report the specific decision if implementation would require a new service, product feature, framework rewrite, protocol translation, destructive migration, weakened transport validation, changed bundle identity, removal of an existing supported feature, publication, or an unapproved external data transfer. Do not invent an alternative product to bypass the issue. Continue independent required work while a genuine owner decision or unavailable physical resource remains unresolved.

If an attempted fix needs a third repair of the same defect, stop and explain the incorrect design assumption and the smallest conventional alternative before adding another patch, as required by the governing instructions.

## Definition of done and developer delivery

The owner asked for feature completeness, polish, and release engineering. Completion means the required behavior works and the evidence matches the actual release configuration, not that an agent has asserted an app is universally bug-free.

Deliver:

1. The implementation of ML 01 through ML 09, preserving the product contract and existing data/features.
2. Updated setup/build documentation only where the implemented UI or build workflow changed. Do not duplicate this spec into several competing plans.
3. Functional evidence for the acceptance matrix, including screenshots of the final UI and actual request/store outcomes for the data and failure paths. Identify device, OS, build mode, endpoint type, and iCloud configuration for executed checks.
4. A concise final change report mapping each requirement ID to its implementation and proof. List known defects, exact unverified physical/configuration checks, and any owner decision still required. Distinguish source inspection, automated tests, simulator execution, physical-device execution, and archive verification.
5. A clean handoff of the changed files and any created test resources. Leave unrelated user changes untouched. Do not merge, publish, submit, or claim external acceptance without that action and its evidence.

Acceptance is satisfied when ordinary setup, chat, offline drafting, model selection, safe revision, recovery, accessibility, and native release flows pass their specified checks and no known defect remains in those checked flows. A required check that cannot run remains incomplete: identify the missing device, configuration, or owner input and label release readiness unverified. Reporting that limit is an honest handoff, not a passing result. Adding more features is not a substitute for finishing these outcomes.
