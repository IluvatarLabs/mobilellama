# MobileLlama iOS submission

**Resubmitted October 18, 2026 at 9:46 AM PDT. Apple confirms Waiting for Review for 1.4.0 (8).**

[App Store Connect receipt](https://appstoreconnect.apple.com/apps/6817933881/distribution/reviewsubmissions/details/ecbdc872-d845-4eec-ba15-67a33aa0a93d). Apple ID **6817933881**; submission ID `ecbdc872-d845-4eec-ba15-67a33aa0a93d`.

The app is free, with the existing United States availability. Automatic release after approval remains selected. Apple approval and public availability are pending.

## Privacy correction

Apple rejected build 7 under 5.1.1(i) and 5.1.2(i) for insufficient disclosure and permission before AI data sharing. Build 8 requires explicit permission before direct connection checks, generation, and shared-account sign-in. The dialog identifies the configured connection, protocol, exact URL and operator hostname, describes transmitted data and purpose, links the policy, and offers Allow / Don’t allow. Old passive acknowledgements do not count as permission. Users can withdraw direct-server permission in Connections or sign out of Shared chats.

The public privacy policy was updated on main. Review Notes contain the corrected flow and a refreshed private review endpoint, verified on October 18. The review response and direct-server consent screenshot were posted. The October 2 physical-device recording remains attached as evidence of the core chat flow; it does not demonstrate build 8’s new permission dialog.

## Build and validation

| Item | Record |
| --- | --- |
| Source commit | `eb6c4eadc83fe49acadf6d6619653b2c44947673` |
| Signed archive | `build/ios/archive/Runner-AppStore-8.xcarchive` |
| Exported IPA | `build/app-store/build-8/MobileLlama.ipa` |
| IPA SHA-256 | `a87d0f29c3a29fd7060c919f75dc5c733d915af109a584191ff9c7c0838e2a52` |
| Automated regression suite | 178 passed |
| Analyzer | Zero errors or warnings; 81 informational lints |
| iOS UI validation | iPhone 17 Pro Max simulator, iOS 26.5: disclosure, decline, allow, real local-server request/reply, withdrawal, renewed permission; shared-sign-in disclosure and decline |
| Signing | Host and share extension 1.4.0 (8), strict signatures verified; exported CloudKit environment Production |
| Apple processing | Upload succeeded; build processed; encryption declaration completed; build 8 selected and resubmitted |

The direct Ollama and OpenAI-compatible tests observe the request boundary, retained drafts/history, exact destination and withdrawal. The Open WebUI test uses real loopback HTTP to observe authentication and history requests only after permission, then no reopen after sign-out. Native simulator and physical-device proof are distinct. This update was not tested on a connected physical phone. The existing nonblocking PDFium dSYM warning remains; crashes inside that framework may have limited symbolication.

## Submission package

- [Store settings and compliance](form-answers.md)
- [Reviewer instructions with private URL redacted](review-notes.txt)
- [Signing and upload](signing-and-upload.md)
- [Review server lifecycle](review-service.md)

Review URLs and credentials stay outside the repository. Build 7 and older submission archives are historical records and must not be confused with build 8. The additive CloudKit schema deployed October 7 remains unchanged by this correction.
