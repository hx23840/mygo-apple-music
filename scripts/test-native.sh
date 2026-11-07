#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/build/module-cache"
xcrun swiftc -swift-version 5 -module-cache-path "$ROOT/build/module-cache" \
  "$ROOT/native/Protocol.swift" "$ROOT/tests/native/main.swift" -o "$ROOT/build/native-tests"
"$ROOT/build/native-tests"
