# dmgbuild settings for the Syrtis installer DMG.
#   dmgbuild -s settings.py -D app=/path/Syrtis.app -D bg=background.tiff "Syrtis" Syrtis.dmg
import os.path

application = defines.get("app", "Syrtis.app")  # noqa: F821 (dmgbuild injects `defines`)
appname = os.path.basename(application)

format = "UDZO"
filesystem = "HFS+"
files = [application]
symlinks = {"Applications": "/Applications"}

background = defines.get("bg", "background.tiff")  # noqa: F821
# 400 pt of content plus the chrome macOS 27's Finder shows whatever the
# .DS_Store asks (toolbar/path bar and status bar, about 95 pt).
window_rect = ((200, 120), (660, 495))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 13
# .background.tiff is left unplaced on purpose. With "show hidden files" on,
# Finder draws it below the art (the window then scrolls); placed inside the
# canvas it was more conspicuous (maintainer, 2026-09-28).
icon_locations = {appname: (170, 205), "Applications": (490, 205)}
