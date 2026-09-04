## Before you update

**The "10% of quota ~ …" line will read lower on some windows, and that is the fix.** [#260](https://github.com/Nanako0129/TokenBar/pull/260)

That line divides the usage recorded during a window by how much quota the window consumed. It was measuring the consumption as the distance between the first and the last reading. When a reading goes down — a reset, or the provider correcting a number it reported earlier — that distance collapses, while the usage above the line still counts everything on both sides of the drop. The smaller the leftover distance, the larger the number.

On one real window the readings travelled 95 points and ended 10 above where they started, so a full window of usage was being divided by 10. The line read several thousand dollars.

Only windows whose readings went down at some point are affected. Where the readings only rose, the two measurements are the same number and nothing changes.

Nothing was lost and nothing needs rebuilding.

## Features

- **The menu-bar text color is configurable.** [#265](https://github.com/Nanako0129/TokenBar/pull/265) — thanks @Agugu-official

  Settings gains a Font color section under Menu bar, offering Automatic and Custom. Automatic is unchanged: quota remaining keeps the built-in green / amber / red, and other titles keep the system color. Custom sets three colors of your own against the thresholds the gauge already uses — above 25% remaining, above 10% through 25%, and 10% or below — with 16 presets and a `#RRGGBB` field. Each individual client item uses its own remaining value, so they can differ from one another.

  Switching back to Automatic keeps all three colors for later.

- **A reported cost the local pricing table cannot justify is now flagged.** [#264](https://github.com/Nanako0129/TokenBar/pull/264)

  Some clients record their own per-message cost, and TokenBar ships those figures as reported rather than pricing the tokens itself. That is the right default — the client knows its own billing contract — but it means a unit error upstream reaches the screen with nothing in between. One report showed a model at $8,647 for 74M tokens.

  Such a row now carries an amber warning beside the cost, and the tooltip names the multiple it is of the local estimate. The figure itself is not corrected: the app cannot know your real rate, only that this one is far from any price it can justify. The threshold is 50x, so a normal row cannot reach it, and a model the table cannot price produces no flag rather than a false one.

## Fixes

- **With a second Claude account, each account's usage was counted against every account's quota.** [#261](https://github.com/Nanako0129/TokenBar/pull/261)

  Every quota-window surface folded both accounts' transcripts into whichever account's allowance it was dividing by. Measured against a reporting store, the primary account's figures ran 1.40x high and the second account's 3.51x — the smaller account is hit harder, because it receives the same numerator against much less quota movement.

  Each account is now scanned separately, against its own registered root. Single-account installs are unaffected, and no stored data changes format.

  Two limits are left in place rather than papered over. A transcript sitting under both accounts' roots is counted for both, because nothing in it says which account produced it — measured at 2 messages in 10,389 on the machine this was built against. And usage you attributed to Claude from another client stays with the primary account: an attribution names a client, a provider and a model, and carries no account for it to follow.

- **Consumption measured across a drop now has to clear the estimate's bar once per rise.** [#260](https://github.com/Nanako0129/TokenBar/pull/260)

  The other half of the same correction. Usage summed across a drop is several separate measurements added together, each carrying its own rounding, so the quoted ± is now one rounding step per rise over the whole consumption rather than one step over the displacement. It can come out either narrower or wider than the figure you saw before, depending on which of the two moved more. A window with enough movement still gets its estimate; one that no longer clears the bar reads "too little to estimate" instead of a confident number.

- **The Models list gained the hover tooltip every other card already had.** [#264](https://github.com/Nanako0129/TokenBar/pull/264)

  A long model name in that tooltip now wraps instead of being truncated.
