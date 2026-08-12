# Releasing FaceLock

FaceLock has two distribution tracks:

1. **Local/portfolio build:** an ad-hoc-signed Apple Silicon app. This is useful on your own Mac, but downloaded copies trigger Gatekeeper and may need privacy permissions granted again after updates.
2. **Public build:** a Developer ID-signed and Apple-notarized app. This is the correct option for a GitHub Release intended for other users.

## Build the local app

Run:

```sh
zsh scripts/build-release.sh
```

The script creates a versioned archive such as `dist/FaceLock-1.0.2-macOS-arm64.zip` plus a SHA-256 checksum. Unzip it, move `FaceLock.app` to `/Applications`, launch it, and grant Camera and Accessibility permissions to that installed copy.

The current machine has no usable code-signing identity, so this local build is ad-hoc signed. Do not present it as notarized.

## Put the source on GitHub

The AdaFace weight is about 124 MB, above GitHub's normal 100 MiB object limit. It is declared as a Git LFS object in `.gitattributes`.

```sh
git init
git lfs install --local
git add .
git commit -m "Initial FaceLock release"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/FaceLock.git
git push -u origin main
```

Everyone cloning the project needs Git LFS installed and should run `git lfs pull` if the model is not downloaded automatically.

Do not commit `dist/`, Xcode `xcuserdata`, archives, signing certificates, notarization credentials, passwords, or exported Keychain data.

## Publish a GitHub Release

Create tag `v1.0.0`, draft a GitHub Release, and attach:

- `FaceLock-1.0-macOS-arm64.zip`
- `FaceLock-1.0-macOS-arm64.zip.sha256`

State clearly whether the archive is notarized. Keep the security warning from the README in the release notes.

## Proper Developer ID distribution

Join the Apple Developer Program, create a **Developer ID Application** certificate, select your team in Xcode, archive a Release build, and export it with Developer ID signing. Submit the ZIP/DMG with `notarytool`, wait for acceptance, staple the ticket, and verify with `spctl` before publishing.

Store notarization credentials in a Keychain profile, never in this repository. Apple notarization checks signing and malware; it does not make FaceLock an official authentication mechanism or remove the password-vault risks described in the README.
