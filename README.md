# FaceLock

<p align="center">
  <strong>Local face recognition for your Mac—built as a native SwiftUI menu-bar app.</strong>
</p>

<p align="center">
  <a href="https://github.com/arjun1223/FaceLock/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/arjun1223/FaceLock?display_name=tag&sort=semver"></a>
  <img alt="macOS 14 or newer" src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple%20Silicon-native-42f579">
  <img alt="Swift 5.9 or newer" src="https://img.shields.io/badge/Swift-5.9%2B-f05138?logo=swift&logoColor=white">
  <img alt="No networking" src="https://img.shields.io/badge/networking-none-42f579">
  <a href="LICENSE"><img alt="MIT license" src="https://img.shields.io/badge/license-MIT-blue"></a>
</p>

FaceLock is a macOS 14+ portfolio/research project that detects and recognizes a face locally, checks basic liveness and eye attention, and then attempts to fill the real macOS password with Accessibility-approved HID-style events. Camera frames, recognition, encryption, and matching stay on the Mac. The app contains no runtime networking, analytics, telemetry, advertising, accounts, or cloud sync.

> [!CAUTION]
> FaceLock is **not Apple Face ID** and is not part of macOS's trusted authentication path. Third-party apps cannot replace or intercept `loginwindow` without unsupported system modifications, which FaceLock does not make. The autofill mechanism is experimental, can stop working after a macOS update, and is not a production security control. 

## Download

### Requirements

- Apple Silicon Mac
- macOS 14 Sonoma or newer
- Front-facing camera
- Touch ID for releasing the password-vault key
- Camera and Accessibility permissions

### Install the app

1. Open the [latest FaceLock release](https://github.com/arjun1223/FaceLock/releases/latest).
2. Download `FaceLock-1.0.2-macOS-arm64.zip`. The tiny `.sha256` file beside it is optional: it lets you verify that the ZIP was not corrupted or changed.
3. To verify, download both files, open Terminal, and run these exact commands:

   ```sh
   cd ~/Downloads
   shasum -a 256 -c FaceLock-1.0.2-macOS-arm64.zip.sha256
   ```

   Terminal should print `FaceLock-1.0.2-macOS-arm64.zip: OK`. You can skip this check if you build FaceLock yourself from reviewed source.

4. Unzip the archive and move `FaceLock.app` to `/Applications` **before granting permissions**.
5. Open FaceLock. It has no Dock icon; look for its face icon in the macOS menu bar.

> [!WARNING]
> Version 1.0 is ad-hoc signed and **not Apple-notarized**. macOS therefore cannot verify its developer or scan result.  If you have reviewed the source and intentionally choose to run this build, first try to open it, then use **System Settings → Privacy & Security → Security → Open Anyway**, following [Apple's official instructions](https://support.apple.com/en-euro/102445). Never use random shell commands from the internet to disable Gatekeeper globally.

## First-time setup

1. Open the FaceLock menu-bar icon and choose **Settings**.
2. Read the Camera and Accessibility rationale, then grant both permissions in **System Settings → Privacy & Security**. Quit and reopen FaceLock after changing permissions.
3. Open **Face Enrollment** and move your head slowly around the circular guide. It captures multiple real poses; simply holding still should not complete enrollment.
4. Open **Security → Test Face Recognition**. Test yourself and at least one other person. Do not lower the default similarity threshold just to force a pass.
5. Choose **Set Up Password Vault**, approve Touch ID, and enter the macOS account password once. For this demo, use a disposable test account.
6. Click **Arm Face Unlock for This Session** and approve Touch ID. Arming is required again whenever FaceLock restarts.
7. Lock the Mac. On wake, face the camera with both eyes visible and look toward it. FaceLock falls back silently to normal password entry if recognition, liveness, attention, or autofill fails.

> [!NOTE]
> Version 1.0.1 and later intentionally do not read Keychain items or encrypted face profiles made by pre-release/Xcode builds with another signing identity. If you used a development build, click **Deny** on any old Keychain dialog, quit it, launch the latest release, then enroll and set up the vault once again.

## Everyday use

- FaceLock starts as a menu-bar utility with no Dock icon.
- When the screen is locked, waking the display starts the camera immediately by default. Pressing Space or Return also triggers an immediate attempt.
- A successful identity + liveness + attention decision decrypts the password briefly, attempts the fill, and submits Return.
- The green notch animation appears only after macOS reports that the protected lock screen has disappeared.
- Use the menu to disable attempts, re-enroll, update the stored password, open Settings, or quit.
- After quitting or restarting FaceLock, open Security and arm the session with Touch ID again.

## What is stored—and where

| Data | Location | Leaves the Mac? | Included in this repository? |
| --- | --- | --- | --- |
| Camera frames | Temporary process memory only | No | No |
| Face embeddings | AES-256-GCM encrypted file in `~/Library/Application Support/FaceLock/` | No | No |
| Face-profile encryption key | Local macOS Keychain | No | No |
| Account password ciphertext | Local macOS Keychain | No | No |
| Password-vault key | Touch ID-protected local Keychain item; cached only while armed | No | No |
| Generic AdaFace model | Bundled inside FaceLock | No | Yes, through Git LFS |

The repository contains generic source, tests, documentation, artwork, and a generic pre-trained model. It contains no enrolled face, camera photo, password value, password ciphertext, vault key, Keychain export, API token, or telemetry credential.

## Highlights

- Native Swift 5.9, SwiftUI, AppKit, AVFoundation, Vision, Core ML, CryptoKit, LocalAuthentication, Security, and CoreGraphics.
- Truly mirrored front-camera preview and a progressive Face ID-inspired enrollment circle.
- 65,150,912-parameter AdaFace IR101 WebFace12M model, converted to Core ML and executed on-device.
- 112×112 landmark alignment with 512-dimensional L2-normalized identity embeddings.
- Enrollment gallery plus normalized-profile-centroid similarity scoring.
- Fresh-frame sequence tracking so one camera image cannot count as multiple identity votes.
- A 5-of-7 decision with a safe fast path: if the first five distinct frames all pass, two unnecessary model runs are skipped without weakening the five-vote requirement.
- Single-face, face-size, pose, confidence, capture-quality, passive-movement, open-eye, and camera-attention gates.
- Pose-aware recognition and eye-attention checks support face angles from straight-on at 90° through 125° (35° of head turn in either direction).
- AES-256-GCM face profile encryption and a Touch ID-gated password vault.
- Authoritative `CGSessionCopyCurrentDictionary` lock-state checks immediately before decryption and autofill.
- Prewarmed Core ML and preconfigured 720p camera pipeline for low wake-to-match latency.
- Compact notch-attached success animation.
- Ten unit tests covering model loading, cosine similarity, consensus, quality gates, angle tolerance, liveness, pose, attention, Keychain isolation, and the safe fast path.

## How it works

```text
WakeLockMonitor
    │  confirms the screen is actually locked
    ▼
CameraManager ── Vision landmarks, quality, pose, pupils
    │
    ├── LivenessChallenge + eye-attention votes
    │
    └── 112×112 alignment ── AdaFace IR101 ── encrypted profile comparison
                                                │
                                                ▼
                                  5-of-7 identity decision
                                                │
                                                ▼
                                  Touch ID-armed PasswordVault
                                                │
                                                ▼
                              locked-state recheck + paced HID events
                                                │
                                                ▼
                                macOS unlock-state confirmation
```

The camera's Vision pass supplies quality, pose, liveness, pupil attention, and reusable eye/mouth alignment geometry. Core ML does not repeat the same landmark detection. A frame receives a blended score from its closest enrollment views and the cached normalized whole-profile centroid. Only distinct, current-session frames vote.

## Build from source

The 124 MB model weight is managed by Git LFS. Install Git LFS before cloning:

```sh
brew install git-lfs
git lfs install
git clone https://github.com/arjun1223/FaceLock.git
cd FaceLock
git lfs pull
open FaceLock.xcodeproj
```

In Xcode 16 or newer:

1. Select the **FaceLock** target.
2. Choose your Development Team and, if necessary, change `io.github.arjun1223.FaceLock` to a bundle identifier unique to your team.
3. Select **My Mac (Apple Silicon)** and press Run.
4. Grant Camera and Accessibility permissions to that exact signed build.

Run tests from Terminal:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project FaceLock.xcodeproj \
  -scheme FaceLock \
  -destination 'platform=macOS,arch=arm64' \
  test
```

Create an ad-hoc local Release ZIP:

```sh
zsh scripts/build-release.sh
```

See [RELEASING.md](RELEASING.md) for Developer ID signing and notarization guidance.

## Troubleshooting

### FaceLock is not visible after launch

It is an `LSUIElement` app, so it intentionally has no Dock icon. Look in the menu bar. If needed, quit it from Activity Monitor and relaunch `/Applications/FaceLock.app`.

### Camera does not start

Open **System Settings → Privacy & Security → Camera**, enable FaceLock, then quit and reopen it. Apple documents camera permission management [here](https://support.apple.com/guide/mac-help/allow-use-of-the-camera-and-video-input-mchlf88b936b/mac).

### Face matches but the password is not entered

Open **System Settings → Privacy & Security → Accessibility**, remove stale FaceLock entries, add the copy located in `/Applications`, enable it, and relaunch. Permissions are tied to the app's code signature and location. Apple documents Accessibility permission [here](https://support.apple.com/en-mide/guide/mac-help/mh43185/mac).

Secure Input and `loginwindow` behavior are controlled by macOS. A successful face match does not guarantee that an OS version will accept synthetic HID events.

### It asks me to arm the session

Open **Security → Arm Face Unlock for This Session** and approve Touch ID. The decrypted vault key is intentionally not persisted across FaceLock restarts.

### macOS asks for my “login” Keychain password

Click **Deny** and quit that copy of FaceLock. This means the app's signing identity changed while an older Keychain item still exists. FaceLock 1.0.1 and later use an isolated versioned Keychain namespace and will not query pre-release items. Install the latest release in `/Applications`, then enroll and configure its vault again. Do not enter your account password into an unexpected Keychain dialog merely to make the app continue.

### Recognition is too strict

Improve front lighting, clean the camera, keep your whole face visible, re-enroll slowly through the entire circle, and test again. Keep liveness and attention enabled. Lowering the similarity threshold increases false-accept risk.

### Permissions broke after rebuilding

Development/ad-hoc signatures can change between builds. Remove the old Camera/Accessibility entry, run or install the new build from a stable location, and grant permission again. A stable Developer ID signature is the proper distribution fix.

## Security boundaries

- A real macOS password necessarily exists briefly in process memory during decryption and event construction.
- Storing an encrypted account password creates risk even when its random key is Touch ID-gated.
- RGB camera liveness and attention are weaker than Apple's infrared/depth-assisted Face ID hardware and can be spoofed by sufficiently capable attacks.
- FaceLock has not undergone an independent false-accept/false-reject or penetration-security evaluation.
- Accessibility permission is powerful. Only grant it to a build whose source and checksum you trust.
- The app is intentionally not App Sandbox-enabled because its Accessibility role is incompatible with that sandbox boundary.
- Distributed lock notifications and synthetic input are not supported authentication contracts and may change between macOS releases.
- FaceLock does not disable SIP, patch `loginwindow`, install a privileged helper, or claim to replace FileVault, Touch ID, Apple Watch unlock, or a strong password.

For sensitive findings, follow [SECURITY.md](SECURITY.md) instead of posting exploit details publicly.

## Contributing

Issues and focused pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), keep all runtime behavior local-only, and never include real enrollment profiles, credentials, signing keys, or Keychain exports in test fixtures.

## License and credits

FaceLock's original source is released under the [MIT License](LICENSE), copyright © 2026 Arjun Tyagi.

The bundled Core ML weights are a local conversion of **AdaFace IR101 WebFace12M** from Minchul Kim's [CVLFace release](https://huggingface.co/minchul/cvlface_adaface_ir101_webface12m). AdaFace and CVLFace source are MIT-licensed, but the official model card separately instructs users to cite the AdaFace paper and follow the training dataset's license. FaceLock's MIT license does not replace those upstream model/dataset terms.

The lock-state and HID event approach is adapted from MIT-licensed [HasBrain/FaceUnlock](https://github.com/HasBrain/FaceUnlock). Full license text, model provenance, and the AdaFace paper citation are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

See [CHANGELOG.md](CHANGELOG.md) for release history.
