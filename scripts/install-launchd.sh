#!/bin/bash
# Install (or reinstall) the hourly capture agent. Each run is a no-op once the day is recorded,
# so "hourly" == "daily, retried until the dock is visible for the screenshot".
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.bcldvd.dock-timelapse"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DATA="$HOME/Library/Application Support/dock-timelapse"
BIN="$HERE/.venv/bin/dock-timelapse"

(cd "$HERE" && uv sync -q)
mkdir -p "$DATA" "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string><string>capture</string></array>
  <key>StartInterval</key><integer>3600</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$DATA/capture.log</string>
  <key>StandardErrorPath</key><string>$DATA/capture.log</string>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL -> $PLIST"
echo "Python needing Screen Recording permission: $(readlink -f "$HERE/.venv/bin/python")"
