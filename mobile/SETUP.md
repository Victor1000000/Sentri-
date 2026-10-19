# Sentri mobile: setup

This folder holds the app's source (Dart, Kotlin, Swift) but not the generated Flutter scaffolding.
**None of it has been compiled or run yet.** Expect a few small compile fixes on first build.

## 1. Create the Flutter project and overlay these files

```bash
flutter create --org ng.sentri --project-name sentri sentri_app
cp -R mobile/. sentri_app/        # overlay: lib/, test/, assets/, android/app/src, ios/Runner, pubspec.yaml
cd sentri_app
flutter pub get
```

Keep the generated Gradle files and the generated `MainActivity` package path. If asked about
overwriting `AndroidManifest.xml`, use ours. Delete any generated duplicate `MainActivity.kt`
(for example under `kotlin/ng/sentri/sentri/` the file must be ours).

## 2. Android settings

In `android/app/build.gradle(.kts)`:
- `minSdk = 26`, `compileSdk` and `targetSdk` 34 or higher.
- Kotlin and AGP versions from the generated project are fine.

## 3. iOS settings

1. In `ios/Runner/AppDelegate.swift`, after the Flutter engine/controller exists, call:
   `registerSentriChannel(messenger: controller.binaryMessenger)`
2. Add `SentriIntents.swift` to the Runner target in Xcode.
3. In `Info.plist` add:
   - `NSLocationWhenInUseUsageDescription`
   - `NSLocationAlwaysAndWhenInUseUsageDescription`
   - (If you later add contact picking) `NSContactsUsageDescription`
4. Users bind the alert to the **Action Button** (iPhone 15 Pro+), **Back Tap**
   (Settings, Accessibility, Touch, Back Tap, then Shortcuts, "Send Sentri alert"), or a
   Control Center / Lock Screen control.

## 4. Run

```bash
flutter run --dart-define=API_BASE_URL=http://10.0.2.2:8080     # Android emulator to host backend
flutter test                                                     # unit tests
```

Start the backend first (see `backend/README.md`; `docker compose up` gives Postgres and Redis).
Use `OTP_DEV_ECHO=true` in dev so the OTP is returned instead of texted.

## 5. Known limitations

- **iOS cannot intercept power/volume or run background shake detection.** Button and shake triggers
  work on Android only; on iPhone use the SOS button in the app or the Siri/Shortcuts action.
- **No SMS anywhere in the app.** Alerts go to contacts who have Sentri, as an in-app message plus a
  high-priority push. With no connection the alert is saved on the phone and goes out the moment the phone
  is online again (retried every 10 s, and on any network change). Delivery with no connection at all is
  not possible without SMS or a voice call. The closest option is a nearby Bluetooth / Wi-Fi Direct relay
  through other Sentri phones (Google Nearby Connections). It is not built.
- **Persistent ringing:** a contact's phone rings and vibrates until they tap "I'm responding", the person
  cancels with their real PIN, or someone responds (a `clear` push stops it). Limits: silent mode and Do Not
  Disturb can mute it; Android 14 lets a user swipe away an ongoing notification; Tecno/Infinix/Xiaomi/Oppo/
  Vivo battery managers can kill the app (ask users to allow background activity); the full-screen alert
  needs the USE_FULL_SCREEN_INTENT permission, which Play may restrict.
- **Police numbers near the alert:** the person and their contacts see 112 plus the closest state
  command's lines, each with a dial button (opens the phone app; it never auto-dials). "Closest" is by
  distance to the state capital, so near a border it can pick the neighbour; the card also lists the
  nearby commands. All lines show "Listed by NPF" (they match the Force's published list) and none is "Verified" until a command confirms it.
- **The police are NOT alerted by the app.** An SOS alerts the person's emergency contacts inside the app. For the police, the person (or a contact) taps "Call 112" or a nearby command's line, and the app says so on screen. The server has an automatic police SMS path (`DISPATCH_MODE=sms`) but it stays off: it needs an official intake line and a signed agreement with the Force or a state command, and there is neither today.
- **Android "power x3"** is a screen on/off heuristic and is best effort, off by default.
- **Play Store declarations needed:** foreground service type `specialUse`, Accessibility service (volume gesture),
  overlay permission, battery-optimization exemption. Expect review.
- **Translations** (Hausa, Yoruba, Igbo, Pidgin) are drafts and need native-speaker review,
  including the alert texts.
- Alerts to contacts are shown in the app in the language chosen for them, and pushed with vibration. Nothing is texted to contacts unless the user turns on "Text contacts when I have no data" (off by default). Contacts see an invitation in the app and can accept or decline.
- E2EE sealed payloads are not built. Contacts see the position on a web page (`/r/…` respond page, `/l/…` for offline notices) that the server renders; the server can read it.
- The app does not yet ask for the user's name, so a contact's alert page says "someone needs urgent help" without naming them. Add a name field at onboarding before pilots (see docs/deployment.md, known gaps).

## 6. Push notifications (Firebase)
Push is needed for contacts to be alerted while their app is closed. Without it, contacts see alerts only when they open the app.

1. Create a Firebase project and add an Android app with package `ng.sentri.sentri` (and an iOS app if you ship iOS).
2. Android: put `google-services.json` in `android/app/`. In `android/settings.gradle(.kts)` add the plugin `com.google.gms.google-services` (version 4.4.x, `apply false`), and apply it in `android/app/build.gradle(.kts)`.
3. iOS: add `GoogleService-Info.plist` to Runner in Xcode, enable Push Notifications and Background Modes (Remote notifications), and upload your APNs key in the Firebase console.
4. Backend: set `PUSH_PROVIDER=fcm` and `FCM_SERVICE_ACCOUNT_B64` (see `docs/deployment.md`).
5. Android 13+ asks the user for notification permission on first start after sign-in.

The app signs in, then registers its token with the server. If you add the config files later, restart the app.

- **Appearance:** a sun/moon button beside the round language button (top right, every screen) flips light and dark in one tap, and the choice is saved. In light mode the logo is black; in dark mode the mark is neon green with a white wordmark. Panels that float over other content use frosted glass over soft indigo and lavender light (no green). Text sizes were reduced; the phone's own font-size setting still applies.
