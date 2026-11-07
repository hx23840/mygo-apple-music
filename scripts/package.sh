#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/plugin/bin/MyGoAppleMusic.app"
[[ -x "$APP/Contents/MacOS/MyGoAppleMusic" ]] || { echo 'Build the helper before packaging.' >&2; exit 1; }
codesign --verify --strict "$APP"
ARCH="$(lipo -archs "$APP/Contents/MacOS/MyGoAppleMusic")"
case "$ARCH" in
  arm64|x86_64) ;;
  'arm64 x86_64'|'x86_64 arm64') ARCH=universal ;;
  *) echo "Unsupported helper architectures: $ARCH" >&2; exit 1 ;;
esac
CONFIGURED="$(/usr/libexec/PlistBuddy -c 'Print :MyGoMusicKitConfigured' "$APP/Contents/Info.plist")"
SUFFIX=""
[[ "$CONFIGURED" == true ]] || SUFFIX="-diagnostic"
mkdir -p "$ROOT/dist"
DEST="$ROOT/dist/plugin-darwin-$ARCH$SUFFIX.zip"
[[ ! -e "$DEST" ]] || rm "$DEST"
(cd "$ROOT/plugin" && /usr/bin/zip -qr "$DEST" plugin.json index.js locales bin)
echo "$DEST"
