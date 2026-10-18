# MobileLlama Privacy Policy

Effective October 18, 2026.

MobileLlama is a free, open-source client for AI servers that you choose. No hosted account or AI service is included with MobileLlama. The app does not send chats, files, connection details, or credentials to the developers through telemetry; data goes to the destinations you explicitly choose. The app includes no analytics, advertising, or crash-reporting service.

MobileLlama does send data to a server or optional service when you direct it to use that destination. The sections below explain those transfers and the controls available to you.

## Stored on your device

Chats, drafts, queued follow-ups, earlier versions of edited chats, chat settings, and attached images and documents are stored in the app's local storage. Shared chats also cache downloaded server history and files on your device. Local data remains until you delete the relevant chats, sign out of the relevant shared account, or remove the app.

Server API keys, access tokens, custom gateway-header values, and the Ollama cloud API key are stored in the iOS Keychain. A shared-server password is used to sign in and is not retained after sign-in. Credentials are not included in chat backups or iCloud chat sync.

## Permission for an AI server you choose

Before MobileLlama first contacts a configured AI destination, including to test a connection or sign in, the app identifies the connection, server type, and exact address; explains the data and purpose; and asks you to allow data sharing. Permission applies only to that protocol and address. Saving an address without connecting does not contact it. A changed address requires new permission, and connections saved by an older app version must also be approved before use.

If you use a direct Ollama or OpenAI-compatible connection, a connection check sends credentials and custom gateway headers, when configured, and requests server version, model, and capability information. Generating a response can send your current message, selected conversation history, instructions, model settings and tool state, attached images and document contents, and any web-search results included in the chat.

If you use Shared chats with an Open WebUI server, sign-in sends your email and password, API key, or custom gateway credentials to that server. The app accesses account identity, server chat history, titles, folders, and files so it can display and synchronize them on your device. Messages, selected history, instructions, model settings, resources, and uploaded attachments are sent to that server to generate and store responses. Attachments upload when you add them to a shared chat, before you send its message.

The named server operator may be you, your organization, or an independent AI service. That operator controls its server-side logging, model training, retention, deletion, onward sharing, and any AI providers configured behind the server. MobileLlama does not choose those operators or providers, and there is no default MobileLlama relay between the app and your chosen server. The developers cannot inspect or guarantee the privacy or security practices of an arbitrary server that you select. Allow data sharing only if you trust the operator and accept its privacy policy and terms.

The MobileLlama developers do not use a third-party processor to receive AI data on MobileLlama's behalf. MobileLlama requires any provider it selects in the future to provide the same or equal protection of personal data described in this policy, and this policy will identify that provider. A user-selected server is independent of MobileLlama, so the developers cannot make that confirmation for an arbitrary server; connect only when its own policy provides protections you accept.

## Withdrawing permission and deleting data

For a direct connection, choose **Settings > Connections**, open the connection, and choose **Withdraw AI data sharing**. This stops future connection checks and AI requests to that destination; saved chats and drafts remain on your device. The app will ask again before using it.

For Shared chats, sign out of that connection. Sign-out stops future requests, removes that account's credentials and local cached chats, files, drafts, queues, and pending requests from the device, and requires new permission before reconnecting. It does not delete history or files already stored by the server.

Withdrawing permission or deleting local data cannot recall data already sent. Use the chosen server's controls or contact its operator to inspect or delete server-side data. The operator's retention and deletion policy applies.

## Optional services

- **Web search** is off unless you turn it on and approve its disclosure. Search terms and page addresses are sent with your Ollama cloud API key to Ollama's cloud service at ollama.com. Ollama returns search results and fetched page content; that material can then be included in the chat sent to your selected AI server. [Ollama’s privacy policy](https://ollama.com/privacy) describes its processing, retention, security, and deletion controls. Turn off Web search to stop future web-search requests.
- **iCloud sync** is off unless you turn it on. Chats and attachments are then sent to and stored in your private Apple iCloud account, governed by [Apple’s privacy policy](https://www.apple.com/legal/privacy/). API keys and unsent drafts stay on your device. Turn off iCloud sync to stop future synchronization; manage data already stored in iCloud through Apple's account and storage controls.
- **Dictation** uses Apple's speech recognition, which may send audio to Apple depending on your device and language. Microphone and speech-recognition permissions are requested only when you dictate. **Read aloud** uses voices built into iOS.
- **Backups** are created only when you ask and go only to the destination you choose in the iOS share sheet. They exclude API keys and unsent drafts.

## Children

The MobileLlama developers do not knowingly collect information from anyone, including children. A server or optional service that you choose may have its own age requirements and privacy practices.

## Changes and contact

Changes to this policy are published in this file. Questions: [open an issue](https://github.com/IluvatarLabs/mobilellama/issues).
