## Highlights

- **A flat contribution heatmap.** The usage chart gains a third view alongside the bars and the 3D graph: a year of daily activity as one dense grid, shaded by tokens or by cost. It opens scrolled to the most recent day, and days in the future are not drawn at all, so the latest day sits at the right edge rather than in the middle of an empty remainder of the year. `⌘G` now cycles all three views instead of toggling between two. [#136](https://github.com/Nanako0129/TokenBar/pull/136)

## Changes

- **Claude plans that report per-model weekly caps now surface those windows.** They appear alongside the session and weekly limits rather than being folded into them. [#133](https://github.com/Nanako0129/TokenBar/pull/133)
- The turn count shows a loading state while it is being read, instead of appearing empty. [#132](https://github.com/Nanako0129/TokenBar/pull/132)

## Fixes

- **Reopening the popover no longer recomputes the hourly views.** They now appear immediately, and the cache behind that is bounded, so a long history cannot grow it without limit. [#131](https://github.com/Nanako0129/TokenBar/pull/131)
- Non-square menu-bar animation art — the parrot — is fitted to the bar instead of being stretched to a square. [#137](https://github.com/Nanako0129/TokenBar/pull/137)
