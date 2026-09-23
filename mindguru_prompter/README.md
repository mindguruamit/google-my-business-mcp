# MindGuru Prompter

A personal teleprompter with a camera studio built in. Offline-first, no watermark.

- **Camera studio:** 720p to 8K resolution chips, 24/30/60/120 fps, exposure −2 to +2 EV, zoom 1–10×, tap to focus and expose (yellow square), front/back switch, stabilization, and an HDR toggle. The app reads each lens's real limits from Camera2 (Android) or AVFoundation (iOS). Resolutions the phone can't record stay visible but greyed out.
- **Teleprompter engine:** word-accurate scrolling on a 60 fps (16 ms) ticker at 80–250 WPM. `[pause]` and `[breath]` cues make it hold. Mirror mode flips the text for beam-splitter glass rigs.
- **VoiceTrack:** follows your voice through the whole script. It scrolls back when you repeat a line and adapts speed to your pace. Two engines: the phone's own recognizer (40+ languages), or Vosk, which runs fully offline after a one-time model download.
- **Floating prompter:** Android shows a draggable window over Instagram, TikTok or YouTube. iOS uses a Picture-in-Picture window instead.
- **Script import:** TXT, MD, PDF, DOCX and RTF from the phone, plus Google Docs, TXT, PDF and DOCX from Google Drive.

---

## Requirements

| | Version |
|---|---|
| Flutter | **3.44+**. The current `camera` plugin, which adds real FPS and stabilization control, needs 3.44. Tested with 3.47.5. |
| Dart | 3.12+ |
| Android | 8.0+ (minSdk 26), built with Android Studio's SDK and JDK 17 |
| iOS | 15.0+ (needed for the Picture-in-Picture prompter) |

## Setup

```bash
cd mindguru_prompter
flutter pub get
flutter run            # debug on a connected phone
```

You don't need `build_runner`. The Hive adapters are written by hand in `lib/models/script_model.dart`.

### Build the APK for vivo X200 FE

```bash
flutter build apk --release --split-per-abi
adb install build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

The release build is signed with the debug key so it installs directly with adb. For Play Store distribution, add a release keystore in `android/app/build.gradle.kts`.

### Google Drive import (optional)

Device import works out of the box. Drive import needs your own Google OAuth client, because Google won't issue tokens to an app it doesn't know:

1. In Google Cloud Console, create a project and enable the **Google Drive API**.
2. Create OAuth clients:
   - **Android:** package `com.mindguru.prompter` plus your signing key's SHA-1 (`cd android && ./gradlew signingReport`).
   - **Web application:** its client ID is the "server client ID".
   - **iOS** (if needed): bundle `com.mindguru.prompter`. Add `GIDClientID` and the reversed-client-ID URL scheme to `ios/Runner/Info.plist`, following the `google_sign_in` docs.
3. Build with the web client ID:
   ```bash
   flutter build apk --release --split-per-abi \
     --dart-define=GOOGLE_SERVER_CLIENT_ID=XXXX.apps.googleusercontent.com
   ```

The app only asks for the read-only Drive scope (`drive.readonly`).

### Offline VoiceTrack (Vosk)

Turn it on in Studio → ⚙ → **Offline VoiceTrack**. On first use the app downloads the small model for your chosen language (about 40–50 MB, over Wi-Fi) from the official catalogue at alphacephei.com. After that, tracking needs no internet. With the default engine, Android can also work offline if you install the offline speech pack for your language (Settings → Google → Voice).

---

## Project structure

```
lib/
  main.dart                      App + overlayMain() entry point for the floating window
  utils/constants.dart           VideoResolution, FrameRate, CameraConstants, colors, keys
  utils/app_theme.dart           Dark theme (#0F1115 / #1C1F26 / lime #A7F050, Inter)
  models/script_model.dart       ScriptModel + CueMarker + Hive adapters
  models/script_document.dart    Parser: spoken words, [pause]/[breath] markers, offsets
  services/camera_service.dart   ProCameraService + DeviceCapabilities (platform channel)
  services/teleprompter_engine.dart  60fps scroll clock, WPM, holds, adaptive speed
  services/voice_track_service.dart  speech_to_text + Vosk, whole-script tracking
  services/script_matcher.dart   Fuzzy alignment of speech to script (forward/back/jump)
  services/floating_service.dart Android overlay / iOS PiP
  services/script_import_service.dart  TXT/PDF/DOCX/RTF + Google Drive
  services/script_repository.dart Hive storage + settings + first-run sample
  state/library_cubit.dart       Library state (flutter_bloc)
  screens/library_screen.dart    Script list → studio
  screens/editor_screen.dart     Editor with [pause]/[breath] highlighting
  screens/recording_screen.dart  The studio
  overlay/overlay_main.dart      Floating prompter UI
  widgets/                       ResolutionSelector, FpsSelector, SpeedControl,
                                 TeleprompterView, focus/voice/eye-contact widgets
android/app/src/main/kotlin/com/mindguru/prompter/MainActivity.kt
                                 Camera2 query: SCALER_STREAM_CONFIGURATION_MAP,
                                 min frame durations, high-speed sizes, CamcorderProfile,
                                 stabilization, 10-bit HDR, and the device's market name
ios/Runner/AppDelegate.swift     AVFoundation capability query + PiP prompter
```

## How device detection works

1. `ProCameraService.getDeviceCapabilities()` calls the `com.mindguru.prompter/device` channel.
2. On Android, it reads, for each camera:
   - the MediaRecorder output sizes from `SCALER_STREAM_CONFIGURATION_MAP`
   - the max fps at each size (from `getOutputMinFrameDuration`, capped by the AE target fps ranges)
   - the high-speed (1080p120) sizes
   - `CamcorderProfile` support for 720p, 1080p, 2160p and 8KUHD
3. The 8K chip is enabled only if the phone declares an 8K encoder profile. On the vivo X200 FE it stays grey, with the tooltip *"Not supported on this device - max 4K60"*.
4. The app recognizes the vivo X200 FE from `ro.vivo.market.name`, `ro.product.marketname` or the device name. When detected, it shows the banner *"vivo X200 FE detected: Max 4K60 optimized"*.
5. If the channel fails, the app falls back to built-in profiles: vivo X200 FE is 4K60 with 1080p120 and no 8K, Samsung S2x is 8K30, and other phones default to 1080p30.

FPS rules: 8K is limited to 24 and 30 fps, and switching to 8K sets 30 fps automatically. 4K allows up to 60 fps if the lens reports it. 1440p and lower can use 60 and 120 fps where the hardware reports them. If a frame rate fails to start on a lens, the app drops back to 30 fps and tells you.

---

## Honest limitations (please read)

- **1440p records as 4K.** CameraX and AVFoundation have no 1440p quality preset, so the 1440p chip uses the 4K preset. Its tooltip says so.
- **HDR is a preference only.** The Flutter `camera` plugin records 8-bit SDR and doesn't expose 10-bit HLG. The chip tells you whether your lens supports HDR, but the recorded video is SDR. The phone's own tone mapping still applies.
- **120 fps is best effort.** CameraX normally records through a standard session. Many phones, possibly including the X200 FE, only offer 120 fps in a special slow-motion session that the plugin can't open. When that happens the app falls back to 30 fps and shows a message.
- **The OEM decides what third-party apps get.** Some manufacturers, vivo included, reserve modes like 4K60 for their own camera app. The chips show what the phone actually allows *this* app. If your X200 FE shows 4K30 as the max, that's a vivo restriction.
- **I couldn't confirm the X200 FE's specs or model code.** The capability numbers (4K60 front and rear, 1080p120, 1080p30 ultrawide, no 8K) and the Samsung S25 8K figures come from your spec. I couldn't check them against the phones. The runtime query always overrides them.
- **VoiceTrack while recording (Android).** The Google recognizer and the camera both need the microphone. On some Android builds, the recognizer receives silence while the camera is recording audio. Test on your phone. If the prompter stops following you during a take, switch to **Offline VoiceTrack (Vosk)** and test again.
- **iOS floating prompter.** iOS doesn't let apps draw over other apps, so the prompter runs in a Picture-in-Picture window (800×400). PiP needs an active audio session, which is why `UIBackgroundModes: audio` is set in Info.plist.
- **Android window size.** The Android overlay's 800×400 size is treated as physical pixels and converted to dp, with the width limited to the screen.
- **Not compiled here.** The Dart code passes `flutter analyze` and 31 unit and widget tests. The Kotlin and Swift code was written against the platform APIs but hasn't been compiled or run on a device. The first build on your machine is the real check.
- **PDF import license.** PDF text extraction uses `syncfusion_flutter_pdf`. It's free for individuals and small businesses under Syncfusion's Community License. Commercial use by a larger company needs their license.

## Package substitutions vs. the original spec

| Spec | Used | Why |
|---|---|---|
| `camera ^0.10.5+9` | `camera ^0.12.1` | 0.10.x can't set FPS or stabilization |
| `vosk_flutter` | `vosk_flutter_service` | `vosk_flutter` pins `http ^0.13` and `permission_handler ^10`, which can't install alongside `googleapis` |
| `pdf_text` | `syncfusion_flutter_pdf` | `pdf_text` is unmaintained and doesn't build with current Android Gradle |
| `docx_to_text` | `archive` + `xml` (built in) | `docx_to_text` pins `archive ^3`, which conflicts with Vosk. A DOCX is a zip, so the app reads `word/document.xml` directly |
| `google_fonts` (Inter) | Inter bundled in `assets/fonts` (OFL) | `google_fonts` downloads fonts at runtime, which breaks offline use |

## Quick test checklist (vivo X200 FE)

- [ ] App opens to the Library with the welcome script
- [ ] Tap ▶ on a script and the studio opens with the camera preview
- [ ] Resolution chips: 720p, 1080p, 1440p and 4K enabled; 8K grey with the tooltip
- [ ] "vivo X200 FE detected: Max 4K60 optimized" banner appears
- [ ] 4K + 60 → record → file saved (Gallery › *MindGuru Prompter* album)
- [ ] Speed slider changes the scroll speed
- [ ] Play/Pause scrolls the text; `[pause]` holds for 1.5 s
- [ ] VoiceTrack (ear icon): speaking moves the text; repeating a line scrolls back
- [ ] Record button turns red and the prompter starts scrolling with the take
- [ ] Tap the preview: a yellow focus square appears
- [ ] Front camera: lime eye-contact dot shows under the lens
- [ ] Mirror flips the text
- [ ] Float: the window appears over Instagram or TikTok and can be dragged

## Tests

```bash
flutter analyze
flutter test
```
