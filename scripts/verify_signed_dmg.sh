#!/bin/bash
# Assert that an installer DMG is what a release must ship: signed by the
# expected Developer ID team, notarized with the ticket stapled, accepted by
# Gatekeeper for opening, and holding a Syrtis.app that itself passes
# verify_signed_app.sh.
#
#   scripts/verify_signed_dmg.sh <Syrtis.dmg> <team-id>
set -euo pipefail

DMG="$1"
TEAM="$2"
fail() { echo "error: $*" >&2; exit 1; }

[ -n "$TEAM" ] || fail "no team id given"
codesign --verify --strict "$DMG" || fail "codesign --verify failed on the DMG"
INFO=$(codesign -dv --verbose=2 "$DMG" 2>&1)
grep -q '^Authority=Developer ID Application: ' <<<"$INFO" || fail "DMG not signed with a Developer ID Application certificate"
grep -qx "TeamIdentifier=$TEAM" <<<"$INFO" || fail "DMG team identifier is not $TEAM"
xcrun stapler validate "$DMG" >/dev/null || fail "no stapled notarization ticket on the DMG"
GATEKEEPER=$(spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 || true)
grep -qx 'source=Notarized Developer ID' <<<"$GATEKEEPER" || fail "Gatekeeper does not report Notarized Developer ID for the DMG: $GATEKEEPER"

MNT=$(mktemp -d)
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
hdiutil attach "$DMG" -nobrowse -readonly -noverify -mountpoint "$MNT" -quiet
[ "$(readlink "$MNT/Applications" 2>/dev/null)" = /Applications ] || fail "DMG has no Applications link to /Applications"
"$(dirname "$0")/verify_signed_app.sh" "$MNT/Syrtis.app" "$TEAM"
echo "verified: $DMG"
