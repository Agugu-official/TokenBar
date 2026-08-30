## Fixes

- **Codex quota windows that ended before their advertised reset were deleted rather than recorded.** [#256](https://github.com/Nanako0129/TokenBar/pull/256)

  A sample survived a save only if it belonged to a window that had run to its advertised end, or to the window currently in progress. Codex moves its reported weekly reset ahead of schedule, and a window that ended early matched neither: it never reached completeness, and the moment the reset moved it stopped being the current one. It was dropped in the same save that admitted the new reading, so nothing ever had an interval in which to rescue it.

  Such a window is now closed at the length it actually ran, before that save, so it can qualify as a completed cycle rather than being cleared as a fragment. The retention rule itself is unchanged. A genuine fragment is still dropped.

  How often this bit depends on how often the provider moves its reset, which is server-side behaviour rather than anything local. Measured against one account's raw Codex sample log — 10,911 readings that predate this work and have no retention applied — the reported reset moved beyond the old five-minute tolerance on **11.6% of consecutive readings**. On the same machine over the same period, Claude accumulated 49 completed cycles and Codex accumulated one. That gap is the bug, not a difference in how the two were used.

  The tolerance was the other half of it. Deciding "this is a different window" reused the quantum that smooths the jitter a provider reports *inside* one window, capped at five minutes, so a rolling reset that drifts continuously read as a new window almost every poll. The threshold now scales with the window it judges — thirty minutes on a weekly one, chosen against that sample log. Windows shorter than 28 hours keep exactly the tolerance they had.

  Closing a window does not lower the bar for recording one. It still needs readings at six or more distinct points, the first near its start and the last near its end, with no gap wider than about a third of it. One example from the account above: a window that collected six readings starting three hours in, and nothing before them, fails that bar even when closed at its best possible length. If TokenBar is not running for much of a window, that window is still lost.

  History lost before this update does not come back either. Those samples were deleted at the time rather than mis-recorded, so nothing remains to rebuild from. A Codex window history that is near empty today stays that way and refills from here.

  One exclusion is deliberate. A window cut short by more than a tenth of its length stays out of the pace projection — the deficit marker and run-out forecast that Historical mode learns — because fitting one that stopped at 34% used teaches the projection that a completed cycle ends there, and every forecast after it reads low. Across the fifteen resets measured, twelve ended between 5% and 64%. A window that still ran nine tenths of its advertised length counts as finished and feeds the projection exactly as before, so an early reset in the last few hours of a week costs nothing. Everywhere other than the projection, these windows are shown and counted like any other.
