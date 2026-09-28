#!/bin/bash
# Sign an assembled Syrtis.app with a Developer ID, inside-out, in Sparkle's
# documented order, with the hardened runtime and a secure timestamp (both
# required for notarization).
#
#   scripts/codesign_app.sh <Syrtis.app> <identity> [keychain]
#
# No entitlements are passed: the app needs none (Keychain reads go through a
# child /usr/bin/security process, the Rust core is statically linked, nothing
# is loaded at runtime). Adding one is a maintainer decision, and
# verify_signed_app.sh fails a release whose main executable carries any.
set -euo pipefail

APP="$1"
IDENTITY="$2"
KEYCHAIN="${3:-}"

SIGN=(codesign --force --options runtime --timestamp --sign "$IDENTITY")
[ -n "$KEYCHAIN" ] && SIGN+=(--keychain "$KEYCHAIN")

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
# bundle.sh removes Sparkle's XPC services (only sandboxed apps use them). A
# bundle that still has them would carry unsigned nested code and fail
# notarization later with a less obvious message, so stop here instead.
if [ -e "$SPARKLE/Versions/B/XPCServices" ]; then
  echo "error: $SPARKLE still has XPCServices; bundle.sh should have removed them" >&2
  exit 1
fi

"${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
"${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
"${SIGN[@]}" "$SPARKLE"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
