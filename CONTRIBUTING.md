# Contributing to FaceLock

Thanks for helping improve FaceLock. This is a security-sensitive macOS demo, so small, reviewable changes are preferred.

## Before opening a pull request

1. Install Xcode 16+, Git LFS, and the macOS 14+ SDK.
2. Run `git lfs pull` and confirm the Core ML weight is present.
3. Create a focused branch from `main`.
4. Keep camera frames, embeddings, recognition, and storage entirely local. Network calls, analytics, telemetry, advertising, and cloud synchronization are out of scope.
5. Never commit passwords, password ciphertext, face profiles, camera images, Keychain exports, signing certificates, provisioning profiles, Apple credentials, or notarization credentials.
6. Run the FaceLock test scheme on Apple Silicon.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project FaceLock.xcodeproj \
  -scheme FaceLock \
  -destination 'platform=macOS,arch=arm64' \
  test
```

## Pull request expectations

- Explain what changed, why, and any security or privacy impact.
- Add or update tests for identity decisions, quality gates, liveness, attention, encryption, or lock-state behavior.
- Do not weaken the default threshold, five-vote identity requirement, liveness, attention, or locked-state checks merely to improve a demo pass rate.
- Do not propose disabling SIP, replacing `loginwindow`, bypassing FileVault, or hiding privileged behavior.
- Update the README when setup, permissions, architecture, security boundaries, or release behavior changes.

## Security reports

Do not open a public issue for an exploitable vulnerability. Follow [SECURITY.md](SECURITY.md).
