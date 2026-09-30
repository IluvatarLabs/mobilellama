# MobileLlama Privacy Policy

Effective September 30, 2026.

MobileLlama is a free, open-source chat client for a server you choose. The developers do not collect, receive, store, or sell any of your data. The app has no accounts, analytics, advertising, or crash reporting.

## Stored on your phone

Chats, drafts, queued follow-ups, earlier versions of edited chats, chat settings, and attached images and documents are stored in the app's local storage. Deleting chats removes them from your phone. Server API keys and the Ollama cloud API key are stored in the iOS Keychain and are never included in backups or iCloud sync.

## Sent to the server you choose

When you send a message, the chat's messages, instructions, settings, and attachments are sent to the server you configured for that chat, such as your own Ollama server or an OpenAI-compatible API. That server's operator, not MobileLlama, controls how the data is processed and retained. Checking a connection asks the server only for its version, models, and model capabilities.

## Optional features

- **Web search** is off unless you turn it on. When a model searches, search terms and page addresses are sent to Ollama's cloud service (ollama.com) with your Ollama cloud API key.
- **iCloud sync** is off unless you turn it on. Chats and attachments are then stored in your private iCloud account, governed by Apple's privacy policy. API keys and unsent drafts stay on your phone.
- **Dictation** uses Apple's speech recognition, which may send audio to Apple depending on your device and language. Microphone and speech permissions are requested only when you dictate. **Read aloud** uses voices built into iOS.
- **Backups** are created only when you ask and go only where you send them. They exclude API keys and unsent drafts.

## Children

MobileLlama does not knowingly collect information from anyone, including children.

## Changes and contact

Changes to this policy are published in this file. Questions: [open an issue](https://github.com/IluvatarLabs/mobilellama/issues).
