#!/bin/bash
# Notarize a signed Syrtis.app and staple the ticket to it.
#
#   scripts/notarize_app.sh <Syrtis.app>
#
# Credentials, one of:
#   NOTARY_PROFILE                               a notarytool keychain profile (local)
#   NOTARY_KEY_FILE, NOTARY_KEY_ID, NOTARY_ISSUER_ID   an App Store Connect API key (CI)
#
# `notarytool submit --wait` can exit 0 on a rejected submission, so the
# verdict is read from its JSON output: anything but "Accepted" fails, after
# printing Apple's log for that submission.
set -euo pipefail

APP="$1"
if [ -n "${NOTARY_PROFILE:-}" ]; then
  AUTH=(--keychain-profile "$NOTARY_PROFILE")
else
  AUTH=(--key "${NOTARY_KEY_FILE:?}" --key-id "${NOTARY_KEY_ID:?}" --issuer "${NOTARY_ISSUER_ID:?}")
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
ditto -c -k --keepParent "$APP" "$WORK/submit.zip"

# Bounded wait; a non-zero exit still falls through to the log below.
xcrun notarytool submit "$WORK/submit.zip" "${AUTH[@]}" --wait --timeout 60m \
  --output-format json > "$WORK/result.json" || echo "notarytool submit exited non-zero" >&2
field() { python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))
except Exception: print("")' "$WORK/result.json" "$1"; }
STATUS=$(field status)
ID=$(field id)
echo "notarization $ID: $STATUS"
if [ "$STATUS" != "Accepted" ]; then
  [ -n "$ID" ] && xcrun notarytool log "$ID" "${AUTH[@]}" || true
  exit 1
fi

xcrun stapler staple "$APP"
