#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
DERIVED_DATA="${TMPDIR:-/tmp}/FaceLockReleaseDerived"
OUTPUT_DIR="${1:-${PROJECT_ROOT}/dist}"
PROJECT="${PROJECT_ROOT}/FaceLock.xcodeproj"

mkdir -p "${OUTPUT_DIR}"

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -quiet \
    -project "${PROJECT}" \
    -scheme FaceLock \
    -configuration Release \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    DEVELOPMENT_TEAM= \
    build

APP="${DERIVED_DATA}/Build/Products/Release/FaceLock.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")
ZIP="${OUTPUT_DIR}/FaceLock-${VERSION}-macOS-arm64.zip"

codesign --verify --deep --strict --verbose=2 "${APP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
(
  cd "${OUTPUT_DIR}"
  shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256"
)

echo "Built ${APP}"
echo "Release archive: ${ZIP}"
echo "Checksum: ${ZIP}.sha256"
