#!/bin/bash
# Launch the app in demo mode and capture its windows (UI review).
#   mac/scripts/shoot.sh <out-dir> <name> [app args…]
set -euo pipefail
OUT="$1"; NAME="$2"; shift 2
APP="$(cd "$(dirname "$0")/.." && pwd)/build/Dock Timelapse.app"
pkill -f "Dock Timelapse.app/Contents/MacOS/Dock Timelapse" 2>/dev/null || true
sleep 0.5
open -n "$APP" --args --demo "$@"
sleep 2
open -a "$APP"  # bring it to the front so windows render as active
sleep "${WAIT:-3}"
PID=$(pgrep -f "Dock Timelapse.app/Contents/MacOS/Dock Timelapse" | head -1)
IDS=$("$(cd "$(dirname "$0")/../.." && pwd)/.venv/bin/python" - "$PID" <<'PY'
import sys, Quartz
pid = int(sys.argv[1])
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID):
    b = w.get("kCGWindowBounds", {})
    if w.get("kCGWindowOwnerPID") == pid and b.get("Width", 0) > 50 and b.get("Height", 0) > 100:
        print(w["kCGWindowNumber"])
PY
)
n=0
for id in $IDS; do
  screencapture -x -o -l "$id" "$OUT/$NAME-$n.png"; n=$((n+1))
done
echo "$n window(s) → $OUT/$NAME-*.png"
