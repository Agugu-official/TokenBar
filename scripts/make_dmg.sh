#!/bin/bash
# Assemble the installer DMG around a (signed) Syrtis.app.
#
#   scripts/make_dmg.sh <Syrtis.app> <out.dmg>
#
# Uses only macOS's own tools (ditto, hdiutil), so it can run in the release
# workflow's signing job. The Finder layout is a committed template:
# assets/dmg/DS_Store (window size, icon positions, background reference) and
# assets/dmg/background.tiff (1x + 2x). Both were produced once with dmgbuild
# from assets/dmg/dmgbuild_settings.py and background.html; see
# assets/dmg/README.md to regenerate them after a design change.
set -euo pipefail

APP="$1"
OUT="$2"
ASSETS="$(cd "$(dirname "$0")/../assets/dmg" && pwd)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP" "$STAGE/Syrtis.app"
ln -s /Applications "$STAGE/Applications"
cp "$ASSETS/background.tiff" "$STAGE/.background.tiff"
cp "$ASSETS/DS_Store" "$STAGE/.DS_Store"
# mktemp makes the stage 0700 and CI runs under umask 077; the volume root
# and layout files must be readable by whoever mounts the image.
chmod 755 "$STAGE"
chmod 644 "$STAGE/.background.tiff" "$STAGE/.DS_Store"

# hdiutil on hosted runners fails now and then with "Resource busy"; a
# retry here is cheaper than re-running a release after notarization.
for attempt in 1 2 3; do
  if hdiutil create -quiet -volname Syrtis -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$OUT"; then
    echo "==> $OUT"
    exit 0
  fi
  echo "hdiutil create failed (attempt $attempt); retrying" >&2
  sleep 10
done
echo "error: hdiutil create failed three times" >&2
exit 1
