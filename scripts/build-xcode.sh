#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEAM="${APPLE_MUSIC_TEAM_ID:-}"
BUNDLE_ID="${APPLE_MUSIC_BUNDLE_ID:-}"
ARCH="${APPLE_MUSIC_ARCH:-$(uname -m)}"
if [[ -z "$TEAM" || -z "$BUNDLE_ID" ]]; then
  echo 'Set APPLE_MUSIC_TEAM_ID and APPLE_MUSIC_BUNDLE_ID before building. See docs/BUILDING.md.' >&2
  exit 1
fi
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1;; esac
if [[ ! "$TEAM" =~ ^[A-Z0-9]{10}$ || ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then
  echo 'Invalid development team or Bundle ID.' >&2; exit 1
fi
BUILD=(xcodebuild -project "$ROOT/native/MyGoAppleMusic.xcodeproj" -scheme MyGoAppleMusic
  -configuration Release -destination "platform=macOS,arch=$ARCH"
  -derivedDataPath "$ROOT/build/xcode")
case "${1:-}" in
  --provision) BUILD+=(-allowProvisioningUpdates) ;;
  '') ;;
  *) echo 'Usage: bash scripts/build-xcode.sh [--provision]' >&2; exit 1 ;;
esac
"${BUILD[@]}" \
  DEVELOPMENT_TEAM="$TEAM" PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" \
  ARCHS="$ARCH" ONLY_ACTIVE_ARCH=YES build
SOURCE_APP="$ROOT/build/xcode/Build/Products/Release/MyGoAppleMusic.app"
codesign --verify --strict "$SOURCE_APP"
mkdir -p "$ROOT/bin"
DEST_APP="$ROOT/bin/MyGoAppleMusic.app"
if [[ -e "$DEST_APP" ]]; then rm -rf "$DEST_APP"; fi
ditto "$SOURCE_APP" "$DEST_APP"
codesign --verify --strict "$DEST_APP"
echo "Built Xcode-signed helper: $DEST_APP"
echo 'Run live playback verification; automatic signing does not prove MusicKit App Service is enabled.'
