# Signing and upload record

Build 8 was archived, exported, and uploaded on October 18, 2026 for the privacy-consent correction. Apple processed it successfully. Do not reuse build number 8. Build 7 is the rejected October 7 submission.

Build 8 source: `eb6c4eadc83fe49acadf6d6619653b2c44947673`. Archive: `build/ios/archive/Runner-AppStore-8.xcarchive`. Export: `build/app-store/build-8/MobileLlama.ipa`. SHA-256: `a87d0f29c3a29fd7060c919f75dc5c733d915af109a584191ff9c7c0838e2a52`. Host/extension versions, strict signatures, and exported production CloudKit entitlements were verified. The existing nonblocking PDFium dSYM warning remains.

## Signing used

- Team: Iluvatar Labs LLC, `XU24CNU359`.
- Distribution certificate SHA-1: `6AA7121F45E003BD17D01930EB66E06F30EF96D7`.
- Runner provisioning profile: `MobileLlama App Store`, UUID `88b6ba39-1aca-48c9-9398-fef5609bb945`, expiry September 30, 2027.
- Share Extension provisioning profile: `MobileLlama Share App Store`, UUID `581607a5-2005-4e52-b6ba-af7d565a6c9a`, expiry September 30, 2027.
- Runner Release configuration uses Manual signing and that profile. Do not pass the profile globally to all CocoaPods targets.
- Entitlements retain CloudKit, its production container environment, and production APNs. No local-only entitlement override was used.

The certificate private key remains in the owner's Keychain. It is not in this repository or package.

## Reproduction

For a future upload, choose an unused build number and regenerate Flutter's release configuration. With the installed certificate/profile and current Release settings:

```sh
flutter build ios --release --config-only --no-codesign --build-number=NEXT_BUILD
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/ios/archive/Runner-AppStore.xcarchive archive
xcodebuild -exportArchive \
  -archivePath build/ios/archive/Runner-AppStore.xcarchive \
  -exportPath build/app-store/validated-ipa \
  -exportOptionsPlist docs/app-store/ExportOptions.plist
```

For the completed upload, the same export options used `destination=upload` and `-allowProvisioningUpdates` with the configured Xcode account. Xcode reported Upload succeeded and EXPORT SUCCEEDED. Verify the build in App Store Connect before selecting it.

The build-7 app passed strict recursive signature verification. Production entitlements, the host/extension App Group, and version/build were checked after export. Apple processed it successfully. Upload Symbols Failed for PDFium was a nonblocking warning; a matching upstream dSYM is absent.

## CloudKit

The matching container's additive build-7 schema was deployed to Production on October 7, 2026. `Chat` retains legacy `conversationID` and also has `entityID` String, `revision` String, `deleted` Int64, and `payload` Asset. `Folder` has `entityID` String, `revision` String, `deleted` Int64, and `payload` Asset. Existing fields and roles were preserved. The code uses a private database and the ChatsV2 custom zone through CKSyncEngine; the legacy Chats zone remains migration input. CloudKit security roles apply to public databases, while these records use the user's private database. [Apple's database design guidance](https://developer.apple.com/icloud/cloudkit/designing/).

App Store Connect confirmed “Changes Deployed,” and the Production `Chat` and `Folder` field sets were read back in CloudKit Console. No indexes, existing roles, or production data were changed. A production two-device sync round trip was not run.
