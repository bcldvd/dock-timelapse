#!/bin/bash
# Build "Dock Timelapse.app": the SwiftUI app, the CLI (also the background recorder), the recorder's
# launch agent and the icon, signed with the hardened runtime.
#
#   mac/scripts/build-app.sh                 # arm64, signed with your Apple Development identity (or ad hoc)
#   ARCHS="arm64 x86_64" SIGN="Developer ID Application: …" mac/scripts/build-app.sh   # release
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
BUILD="${BUILD:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-arm64}"
OUT="${OUT:-$PWD/build}"
APP="$OUT/Dock Timelapse.app"
if [ -z "${SIGN:-}" ]; then
  SIGN=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')
  SIGN="${SIGN:--}"
fi

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done
swift build -c release "${arch_flags[@]}" --product DockTimelapseApp
swift build -c release "${arch_flags[@]}" --product dock-timelapse
BIN=$(swift build -c release "${arch_flags[@]}" --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchAgents"
cp "$BIN/DockTimelapseApp" "$APP/Contents/MacOS/Dock Timelapse"
cp "$BIN/dock-timelapse" "$APP/Contents/MacOS/dock-timelapse"
cp Bundle/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Bundle/io.github.bcldvd.DockTimelapse.recorder.plist "$APP/Contents/Library/LaunchAgents/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Bundle/Info.plist > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

opts=(--force --options runtime)
[[ "$SIGN" == Developer\ ID* ]] && opts+=(--timestamp)
codesign "${opts[@]}" --identifier io.github.bcldvd.DockTimelapse.cli --sign "$SIGN" "$APP/Contents/MacOS/dock-timelapse"
codesign "${opts[@]}" --sign "$SIGN" "$APP"
codesign --verify --deep --strict "$APP"
echo "$APP  (signed: $SIGN)"
