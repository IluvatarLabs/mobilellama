# App Store Connect submitted answers

Updated October 7, 2026 after the build-7 resubmission. These settings were saved in App Store Connect.

| Field | Submitted value |
| --- | --- |
| App / Apple ID | MobileLlama / 6817933881 |
| Platform / version / build | iOS / 1.4.0 / 7 |
| Bundle / SKU | `app.mobollama.mobollama` / `mobilellama-ios` |
| Team | Iluvatar Labs LLC / XU24CNU359 |
| Language | English (U.S.) |
| Subtitle | Your models, from your phone |
| Categories | Productivity; Utilities |
| Price / availability | Free ($0.00); United States |
| Other platforms | Mac and Apple Vision Pro availability disabled |
| Release | Automatic after Apple approval |
| Copyright | 2026 Iluvatar Labs LLC |
| Content rights | Necessary rights to third-party content |
| License | Apple standard license agreement |
| Support | https://github.com/IluvatarLabs/mobilellama/issues |
| Marketing | https://github.com/IluvatarLabs/mobilellama |
| Privacy policy | https://github.com/IluvatarLabs/mobilellama/blob/main/PRIVACY.md |
| Privacy choices URL | Blank |
| Account login | No MobileLlama account; direct connections have no app login; optional Open WebUI uses an existing external server account |
| Review contact | Yuan Zhao; existing Apple developer account contact entered privately |
| Review connection | Private HTTPS Ollama URL entered in Review Notes; qwen2.5:3b; no separate API key |
| Review recording | Existing October 2 physical-device core-flow video remains attached to the App Review conversation |
| Screenshots | Four iPhone 6.9-inch and four iPad 13-inch images in numbered order |
| In-app purchases / subscriptions / ads | None |
| App previews / routing coverage / Game Center | None / not applicable / disabled |
| Accessibility declarations | No unverified claims selected |

## Privacy label

**Data Not Collected** was published. No tracking is implemented.

The developer operates no public app account service, inference proxy, analytics, advertising, or crash-upload service. Local data stays on the device unless the user sends, syncs, or exports it. The user selects and authenticates their own Ollama, OpenAI-compatible, or Open WebUI provider. An Open WebUI login is an account on that external server, not a MobileLlama account. Optional web search is a direct REST call to Ollama using the user's own key; no Ollama SDK or vendor code is integrated. Apple services handle private CloudKit storage and speech recognition.

This selection applies Apple's definition of a third-party partner (analytics/ad tools, SDKs, or vendors whose code is added) to the actual implementation. User-selected service operators are not developer collection partners. The published policy separately discloses these transmissions and the operator's control of retention. It does not claim that arbitrary user-selected servers retain no data. See [Apple's definitions](https://developer.apple.com/app-store/app-privacy-details/) and the [published policy](../../PRIVACY.md). Reassess the label if a developer-operated service or vendor SDK is added.

The private review endpoint is supplied only to Apple and is not a public app service or default connection.

## Age rating

Age rating is **18+**, a manual override of the calculated 13+ rating, because users choose general-purpose models without a model-level filter enforced by this client.

- No parental controls, age assurance, unrestricted embedded browser, public user-generated content, social media, user-to-user messaging, ads, gambling, contests, or loot boxes.
- Infrequent profanity/crude humor, horror/fear, alcohol/tobacco/drugs, medical information, mature/suggestive themes, non-graphic sexual content/nudity, cartoon/fantasy violence, realistic violence, and weapons references; wellness topics Yes.
- No graphic sexual content or prolonged graphic/sadistic violence as an app service.

These frequency selections reflect topics possible in general-purpose model conversations, not bundled content. The app is not in the Kids category.

## Encryption questionnaire

- Selected **standard encryption algorithms in addition to Apple's OS encryption**. The PDFium dependency includes AES/RC4 document cryptography; selecting OS-only would be inaccurate.
- Proprietary/nonstandard algorithms were not selected.
- Distribution in France: **No**, matching the saved U.S. storefront selection.
- Apple processed builds 7 and 8. The same encryption declaration was completed for build 8 on October 18, and its status is Ready to Submit. No fabricated document or exemption code was supplied, and the signed binary was not patched.

The source lacks `ITSAppUsesNonExemptEncryption`, so a future build still requires the App Store Connect questionnaire or an accurately determined source declaration. Revisit documentation before expanding into France. [Apple's export documentation](https://developer.apple.com/help/app-store-connect/reference/app-information/export-compliance-documentation-for-encryption/).
