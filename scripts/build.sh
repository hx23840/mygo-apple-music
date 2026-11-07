#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:---diagnostic}"
ARCH="${APPLE_MUSIC_ARCH:-$(uname -m)}"
IDENTITY="${APPLE_MUSIC_SIGN_IDENTITY:-}"
BUNDLE_ID="${APPLE_MUSIC_BUNDLE_ID:-dev.mygo.applemusic.diagnostic}"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported architecture: $ARCH" >&2; exit 1;; esac
case "$MODE" in
  --diagnostic) CONFIGURED=false; IDENTITY=- ;;
  --signed)
    if [[ -z "$IDENTITY" || -z "${APPLE_MUSIC_BUNDLE_ID:-}" ]]; then
      echo 'Set APPLE_MUSIC_SIGN_IDENTITY and APPLE_MUSIC_BUNDLE_ID before a signed build.' >&2; exit 1
    fi
    if [[ "$IDENTITY" == "-" ]]; then echo 'A signed build needs an Apple signing identity.' >&2; exit 1; fi
    CONFIGURED=true ;;
  *) echo 'Usage: bash scripts/build.sh [--diagnostic|--signed]' >&2; exit 1 ;;
esac
if [[ ! "$BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]]; then echo 'Invalid Bundle ID.' >&2; exit 1; fi
APP="$ROOT/plugin/bin/MyGoAppleMusic.app"
mkdir -p "$APP/Contents/MacOS" "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macos14.0" \
  -module-cache-path "$ROOT/build/module-cache" \
  -framework AppKit -framework MusicKit \
  "$ROOT/native/ArtworkCache.swift" "$ROOT/native/Protocol.swift" "$ROOT/native/AppleMusicService.swift" "$ROOT/native/LaunchBridge.swift" "$ROOT/native/main.swift" \
  -o "$APP/Contents/MacOS/MyGoAppleMusic"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>MyGo Apple Music</string>
<key>CFBundleDisplayName</key><string>MyGo Apple Music</string>
<key>CFBundleExecutable</key><string>MyGoAppleMusic</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.2</string>
<key>CFBundleVersion</key><string>5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleMusicUsageDescription</key><string>Connect your Apple Music library and play your songs from MyGo Music.</string>
<key>MyGoMusicKitConfigured</key><$CONFIGURED/>
</dict></plist>
EOF
codesign --force --sign "$IDENTITY" --options runtime "$APP"
codesign --verify --strict "$APP"
echo "Built $MODE plugin for $ARCH: $APP"
