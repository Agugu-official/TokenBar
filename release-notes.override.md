## Antigravity quota when the IDE is closed

Antigravity quota used to vanish the moment you quit the Antigravity IDE. This release keeps it updating whether or not the IDE is running, and shows it even when the IDE is not installed.

## Changes

- Fetch Antigravity quota without the IDE. TokenBar now reads Antigravity quota from your signed-in Google account, and falls back to the Antigravity command-line tool (`agy`) when that is what is available, instead of depending on the running IDE. [#236](https://github.com/Nanako0129/TokenBar/pull/236) — thanks @iF2007

## Fixes

- Fix "OAuth client was not found" on installed IDEs. The scan that reads the sign-in client from the installed Antigravity app could absorb a neighbouring value and reject a valid client id, so an installed-but-closed IDE showed an OAuth error instead of quota. [#242](https://github.com/Nanako0129/TokenBar/pull/242)
