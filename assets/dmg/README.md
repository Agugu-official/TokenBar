# Installer DMG layout

`scripts/make_dmg.sh` builds the release DMG from two committed files, using only `ditto` and `hdiutil`, so it runs inside the release workflow's `sign` job, which runs no third-party tooling:

| File | What it is |
|---|---|
| `background.tiff` | Window background, 660×400 pt, 1x and 2x representations |
| `DS_Store` | Finder layout copied from a dmgbuild-made volume: window size, icon size and positions, background reference. Copied into the volume as `.DS_Store` |

The sources they were made from are kept beside them: `background.html` (the art) and `dmgbuild_settings.py` (the layout).

## Design constraints (measured 2026-09-28, macOS 27)

- Finder draws icon labels in black in both light and dark appearance, so the background stays light.
- Finder shows its toolbar and status bar whatever the `.DS_Store` asks, about 95 pt, so the window is 660×495 for 400 pt of content.
- `.background.tiff` is left unplaced: with "show hidden files" on, Finder draws it below the art (the window then scrolls). Placed inside the canvas it was more conspicuous.
- Whether an extension shows ("Syrtis.app") follows the viewer's Finder preference. A per-file hide-extension flag is not set: `make_dmg.sh` copies only the `.DS_Store`, and "show all filename extensions" overrides the flag anyway.
- Known limit, not checked in CI: `DS_Store` references the background as recorded on the dmgbuild volume. On a fresh mount Finder finds it by path (checked by eye, 2026-09-28). With another volume named `Syrtis` already mounted, the new one mounts as `Syrtis 1` and the reference may resolve to the other volume.

## Regenerating after a design change

Run in a scratch directory outside the checkout, with Google Chrome and a Python virtualenv (`REPO` is the checkout):

```sh
cp "$REPO/assets/dmg/background.html" "$REPO/assets/dmg/dmgbuild_settings.py" .
python3 -m venv venv && ./venv/bin/pip install dmgbuild
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
"$CHROME" --headless=new --force-device-scale-factor=2 --window-size=660,400 \
  --hide-scrollbars --virtual-time-budget=8000 --screenshot=bg@2x.png "file://$PWD/background.html"
sips -z 400 660 bg@2x.png --out bg.png
tiffutil -cathidpicheck bg.png bg@2x.png -out background.tiff
./venv/bin/dmgbuild -s dmgbuild_settings.py -D app=/path/to/Syrtis.app -D bg=background.tiff "Syrtis" layout.dmg
hdiutil attach layout.dmg -nobrowse -readonly -mountpoint ./mnt
cp mnt/.DS_Store DS_Store && hdiutil detach ./mnt
```

Copy `background.tiff` and `DS_Store` back here, then open a DMG built by `scripts/make_dmg.sh` and check the window by eye: the layout lives in a binary file, so a review of the diff cannot show it. The volume name (`Syrtis`) and the background file name (`.background.tiff`) are part of the layout and must match `make_dmg.sh`.
