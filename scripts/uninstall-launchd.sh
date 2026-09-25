#!/bin/bash
LABEL="com.bcldvd.dock-timelapse"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
echo "Removed $LABEL (data kept in ~/Library/Application Support/dock-timelapse)"
