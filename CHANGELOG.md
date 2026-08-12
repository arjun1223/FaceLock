# Changelog

All notable FaceLock changes are recorded here.

## 1.0.2 — 2026-08-12

### Improved

- Extended face recognition from the straight-on 90° position through a 125° facing angle (35° of yaw in either direction).
- Added pose-aware Vision quality and pupil-attention tolerances for moderate head turns while retaining the normal stricter frontal checks.
- Added live face-angle feedback to the recognition test and clearer lock-screen scan guidance.
- Isolated 1.0.2 encrypted data from earlier ad-hoc-signed packages so an upgrade cannot summon the login-Keychain password dialog; this requires one fresh enrollment and vault setup.

## 1.0.1 — 2026-08-12

### Fixed

- Isolated public builds from Keychain items and encrypted face profiles created by differently signed pre-release/Xcode builds.
- Prevented passive password-vault status checks from displaying authentication UI.
- Clarified how to dismiss the legacy login-Keychain prompt and set up the public build cleanly.
- Simplified SHA-256 download-verification instructions.

## 1.0.0 — 2026-08-12

### Added

- Native macOS menu-bar app and SwiftUI settings window.
- Mirrored, progressive multi-pose face enrollment.
- Local AdaFace IR101 WebFace12M Core ML identity embeddings.
- Fresh-frame 5-of-7 matching with a safe five-pass fast path.
- Vision capture-quality, single-face, pose, passive-liveness, pupil-attention, and open-eye checks.
- AES-256-GCM encrypted face profiles and a Touch ID-gated password vault.
- Wake/lock monitoring, authoritative lock-state checks, and experimental paced HID password autofill.
- Test-recognition mode and compact notch-attached unlock animation.
- App icon, Git LFS model handling, Release packaging script, SHA-256 checksums, and eight unit tests.

### Security notice

FaceLock remains an unofficial research/portfolio demo. Version 1.0.0 is ad-hoc signed and not Apple-notarized.
