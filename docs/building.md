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

Open `ios/Runner.xcworkspace` in Xcode. Select the Runner target, choose your
Apple team under Signing & Capabilities, and use a bundle identifier registered
to your team. Connect and trust your phone, and enable Developer Mode.

For a local build without iCloud, including a free Personal Team, run:

```sh
flutter build ios --release --config-only --no-codesign \
  --dart-define=MOBILELLAMA_ICLOUD=false
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/ios/local-device -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_ENTITLEMENTS="$PWD/ios/Runner/Local.entitlements" build
```

Install `build/ios/local-device/Build/Products/Release-iphoneos/Runner.app`
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

Exercise UI changes in the simulator and include screenshots in your PR.
Describe the change and how you checked it. For bugs, include the app version,
device, server type, and steps to reproduce; leave out API keys and private chats.

Android development uses the Android SDK and the usual Flutter build commands.
Android testing and fixes are community-supported.
