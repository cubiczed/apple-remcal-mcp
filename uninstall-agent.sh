#!/usr/bin/env zsh
set -euo pipefail

PLIST="$HOME/Library/LaunchAgents/com.zayden.apple-remcal-mcp.plist"
UID_NUM="$(id -u)"

launchctl bootout "gui/$UID_NUM/com.zayden.apple-remcal-mcp" 2>/dev/null || true
rm -f "$PLIST"
echo "Stopped and removed LaunchAgent: $PLIST"
