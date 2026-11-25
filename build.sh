#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/build/AppleRemCalMCP.app"
MACOS_DIR="$APP/Contents/MacOS"

rm -rf "$APP"
mkdir -p "$MACOS_DIR"

swiftc -O -swift-version 5 \
  -framework Foundation \
  -framework EventKit \
  "$ROOT/Sources/EventKitStore.swift" \
  "$ROOT/Sources/MCPHandler.swift" \
  "$ROOT/Sources/HTTPServer.swift" \
  "$ROOT/Sources/main.swift" \
  -o "$MACOS_DIR/AppleRemCalMCP"

cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
du -sh "$APP"
