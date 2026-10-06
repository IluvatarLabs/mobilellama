# Building MobileLlama

Use Flutter with Dart 3.13.2 or later. For iOS, you'll also need macOS, Xcode,
and CocoaPods. Follow [Flutter's iOS setup guide](https://docs.flutter.dev/platform-integration/ios/setup)
to install the tools and set up a simulator or phone.

## Simulator

Start an iOS simulator, then run these commands from the repository root:

```sh
flutter pub get
flutter run --dart-define=MOBILELLAMA_ICLOUD=false
```

Use `flutter devices` and `flutter run -d <device-id>` if more than one device
is available; keep the same `--dart-define` flag.

## iPhone

Open `ios/Runner.xcworkspace` in Xcode. Configure **both Runner and
ShareExtension** under Signing & Capabilities with the same Apple team. Each
target needs its own registered bundle identifier and provisioning profile.
Assign the same App Group to both targets. The checked-in group is
`group.app.mobollama.mobollama`; when using another identifier, update both
entitlements and the matching group strings in `AppDelegate.swift` and
`ShareViewController.swift`. Connect and trust your phone, and enable Developer
Mode.

For a local build without iCloud, run:

```sh
flutter build ios --release --config-only --no-codesign \
  --dart-define=MOBILELLAMA_ICLOUD=false
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios/local-device -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  PROVISIONING_PROFILE_SPECIFIER= \
  CODE_SIGN_IDENTITY="Apple Development" \
  CODE_SIGN_ENTITLEMENTS="$PWD/ios/Runner/Local.entitlements" build
```

App Group provisioning is still required when iCloud is disabled. Install
`build/ios/local-device/Build/Products/Release-iphoneos/Runner.app`
through Xcode's Devices and Simulators window. Keep the same bundle identifier
when updating an existing installation to retain its data.

## Optional iCloud support

The commands above disable iCloud. To build with it, omit the compile-time flag
and local entitlement override, and configure your own CloudKit container in
`ios/Runner/DebugProfile.entitlements`, `ios/Runner/Release.entitlements`, and
`ios/Runner/ChatCloudSync.swift`. Follow [Apple's CloudKit documentation](https://developer.apple.com/documentation/cloudkit)
for account capabilities and container setup.

## Tests and contributions

```sh
flutter analyze
flutter test
```

Native workflow tests use the existing integration driver, for example:

```sh
flutter drive --driver=test_driver/integration_test.dart \
  --target=integration_test/shared_chat_workflow_test.dart \
  -d <simulator-id> --dart-define=MOBILELLAMA_ICLOUD=false
```

Opt-in live checks are in `test_driver/live_backend_test.dart`,
`test_driver/live_webui_test.dart`, and
`integration_test/live_shared_workflow_test.dart`, and
`integration_test/live_account_acceptance_test.dart`. Read each file's required
environment/configuration fields before running. Use a disposable authenticated
server account; these checks create conversations, folders, and uploaded files.
The live account check requires a disposable Open WebUI instance with separate
admin and A/B accounts. It exercises roles and permissions and restores them
afterward. Keep credentials outside the repository. Fixture tests, live-server checks, and
physical-device acceptance are separate evidence.

## Distribution

Runner and ShareExtension must have the same version and build number. Both
read `FLUTTER_BUILD_NAME` and `FLUTTER_BUILD_NUMBER` from Flutter's generated
configuration. Increment `pubspec.yaml` or pass `--build-number` consistently.
The maintained `docs/app-store/ExportOptions.plist` maps both bundle identifiers
to this project's distribution profiles. Replace its team/certificate/profile
values for another developer account. Then run:

```sh
flutter build ipa --release --export-options-plist=docs/app-store/ExportOptions.plist
```

Check the embedded signatures, profiles, and App Group entitlement on both
bundles. An exported IPA is a build artifact; it does not establish physical
device acceptance or App Store review status.

Exercise UI changes in the simulator and include screenshots in your PR.
Describe the change and how you checked it. For bugs, include the app version,
device, server type, and steps to reproduce; leave out API keys and private chats.

Android development uses the Android SDK and the usual Flutter build commands.
Android testing and fixes are community-supported.
