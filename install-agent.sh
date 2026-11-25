#!/usr/bin/env zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_BIN="$ROOT/build/AppleRemCalMCP.app/Contents/MacOS/AppleRemCalMCP"
PLIST="$HOME/Library/LaunchAgents/com.zayden.apple-remcal-mcp.plist"
UID_NUM="$(id -u)"

if [[ ! -x "$APP_BIN" ]]; then
  echo "App binary not found at $APP_BIN. Run ./build.sh first." >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zayden.apple-remcal-mcp</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_BIN</string>
        <string>--port</string>
        <string>8787</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/apple-remcal-mcp.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/apple-remcal-mcp.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID_NUM/com.zayden.apple-remcal-mcp" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
echo "Installed and started LaunchAgent: $PLIST"
