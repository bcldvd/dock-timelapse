#!/bin/bash
# Package "Dock Timelapse.app" into a drag-to-Applications DMG, then sign, notarize and staple it when
# credentials are available.
#
#   mac/scripts/make-dmg.sh                                  # after build-app.sh
#   NOTARY_PROFILE=dock-timelapse mac/scripts/make-dmg.sh    # notarize with a stored notarytool profile
#   NOTARY_KEY=AuthKey.p8 NOTARY_KEY_ID=… NOTARY_ISSUER=… mac/scripts/make-dmg.sh   # App Store Connect API key (CI)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.3.0}"
OUT="${OUT:-$PWD/build}"
APP="$OUT/Dock Timelapse.app"
DMG="$OUT/Dock-Timelapse-$VERSION.dmg"
[ -d "$APP" ] || { echo "Build the app first: mac/scripts/build-app.sh" >&2; exit 1; }
SIGN="${SIGN:-$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1 || true)}"

notarize() {  # $1 = file to submit
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$1" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  fi
}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Dock Timelapse.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -quiet -volname "Dock Timelapse" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG"
if [ -n "$SIGN" ] && [ "$SIGN" != "-" ]; then
  codesign --force --sign "$SIGN" "$DMG"
fi

# With credentials, a notarization or stapling failure fails the build (set -e).
if [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_KEY:-}" ]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  echo "Notarized and stapled."
else
  echo "Not notarized (no NOTARY_PROFILE or NOTARY_KEY). Fine for testing; required for public downloads."
fi
hdiutil verify -quiet "$DMG"
echo "$DMG ($(du -h "$DMG" | cut -f1))"
