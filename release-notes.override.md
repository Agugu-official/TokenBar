## Before you update

**The dashboard rebuilds once.** The saved snapshot now records which scan roots produced it, so a snapshot written by the previous version is not restored on the first launch after updating. Expect one cold start and nothing else.

**Downgrading after this release loses your quota pace history.** [#234](https://github.com/Nanako0129/TokenBar/pull/234)

The store holding those readings moves from schema 3 to schema 4. An older TokenBar cannot read the new format — it treats the file as corrupt, quarantines it, and starts accumulating from nothing. Your usage totals are unaffected: those are read from your logs and can always be recomputed. The pace readings cannot. They are observations taken over time, and weeks of them are what let a window say "Historically: lasts until reset" rather than falling back to a flat average.

Upgrading itself loses nothing. The migration exists precisely so that a version bump does not reset everyone's history, and it preserves every sample exactly.

The conversion is lazy: it happens on the next write the app had its own reason to make, not on load. So a file still reading `"schemaVersion": 3` for a while after updating is normal, and not a migration that failed to run.

## Features

- **Quota gets its own lens.** [#227](https://github.com/Nanako0129/TokenBar/pull/227)

  A quota percentage tells you how much is left and nothing about what spent it. The window card draws the subscription's quota over time with the local usage that moved it underneath, on the same axis, so a flat stretch of quota can be read against the work that was or was not happening. The line is the provider's reading; the bars are your transcripts.

  Under it, four more answers that a single percentage cannot give. **Past windows** lists every recorded reset cycle as its own row, expandable to a per-model breakdown. **Equivalence** estimates what one percent of the allowance costs in tokens and dollars, pooled across the cycles that carry enough evidence to say — and reports which of those conditions is missing when it cannot. A **weekday heatmap** shows when in the week the allowance actually goes. An **Overview summary** card carries the shape of it back to the front page, and Overview cards can now be hidden individually.

  Quota window rows also carry a recent-trend indicator, so a row shows direction rather than only level.

- **A model-scoped quota window now counts only its model.** [#231](https://github.com/Nanako0129/TokenBar/pull/231)

  Claude reports scoped weekly limits — a "Fable only" allowance alongside the general one. The line drawn for such a window was that allowance, but the usage drawn underneath it was the whole subscription's, so the bars were explaining a quota they had not moved. The chart, the history rows and the cost estimate now all narrow to the model the allowance charges.

  The join is between two naming systems and is treated as one: the provider identifies the scope by display name — it sends no model id — while your transcripts carry a canonical id. When nothing local matches, the card says the scope matched nothing rather than drawing an empty week, because an empty chart under a moving quota line would claim you did no work.

- **Claude scan roots can be added in Settings.** [#230](https://github.com/Nanako0129/TokenBar/pull/230)

  A second Claude account kept under its own `CLAUDE_CONFIG_DIR` is invisible to a scan that reads only the default location. Those directories can now be registered, and a root that is temporarily unreachable — an unmounted volume, a directory not yet created — is kept and retried on the next scan rather than dropped from your configuration.

- **A second Claude account gets its own quota card and its own history.** [#235](https://github.com/Nanako0129/TokenBar/pull/235)

  An account kept under its own `CLAUDE_CONFIG_DIR` is fetched, identified and recorded separately from the main one, so each card carries its own plan label and accumulates its own reset cycles rather than sharing a single series.

  **One limit is deliberate.** When an additional account's token expires, TokenBar does not refresh it in place. The card says so and asks you to run `claude` under that `CLAUDE_CONFIG_DIR`. The credential refresh path reloads, validates and saves against the main configuration directory throughout, so sending an additional account through it would write that account's token over your main account's stored credential and log you out of the main account. It fails closed instead, which is a worse experience than a silent refresh and a much better one than a silent logout.

- **Long quota windows are sampled about four times as often.** [#227](https://github.com/Nanako0129/TokenBar/pull/227)

  The quota history keeps one reading per slice of a cycle rather than one per interval, which on a seven-day window meant a reading roughly every 3.5 hours — a curve made of a handful of points while the headline above it moved. Windows longer than two days now use a finer grid, about one reading an hour. A window sitting at its full allowance also records that starting point, instead of waiting for the first spend to establish where the cycle began.

## Fixes

- **Opening and closing the popover repeatedly no longer risks Anthropic's rate limit.** [#227](https://github.com/Nanako0129/TokenBar/pull/227)

  Three independent callers fetch the quota payload — the popover's poll loop, the Settings window's own loop, and the tray refresh — and each is written to call first and sleep after. The popover's loop is mounted by the view, so it restarted on every open and issued its leading call immediately. Ten opens issued ten requests with nothing in between, which is enough to reach the limit on `oauth/usage`. The engine already handled the aftermath of a 429; nothing bounded the attempts that produce one.

  Requests now share a floor, and callers arriving together share one request rather than opening three. A request that is itself slow is timed from when it returned rather than from when it was asked — timing it from the ask made a slow response land already expired, so the next reopen fetched again, dissolving the protection exactly while the endpoint was struggling.

- **Usage from a previous account no longer survives a change of credential target.** [#223](https://github.com/Nanako0129/TokenBar/pull/223)

  Switching the durable authentication target left the prior account's usage on screen until something else happened to replace it.

- **The cycle still running no longer appears under past windows.** [#227](https://github.com/Nanako0129/TokenBar/pull/227)

  It was listed beside completed cycles as though comparable, and counted toward the three-cycle threshold the cost estimate needs — so an estimate could change under the reader as the cycle filled. The engine now marks which readings belong to the open cycle, rather than the display inferring it from a timestamp the two sides quantise differently.

- **A source you excluded is no longer reported back as unclassified.** [#227](https://github.com/Nanako0129/TokenBar/pull/227)

  Excluding a source *is* classifying it. The line naming what else was active in a window folded "you excluded this" together with "you have not looked at this yet", so it presented a decision you had already made as an open question.

- **Launching no longer throws away caches that were still valid.** [#233](https://github.com/Nanako0129/TokenBar/pull/233)

  The scan-root list is pushed to the engine at every launch and on every settings save, not only when the list has changed — and doing so dropped every cached scan result and advanced the marker that forces a reload, unconditionally. So an ordinary launch paid to rebuild what it already had, and a popover open at the wrong moment additionally took a full forced rescan for a root set identical to the one already installed. Both now happen only when the installed roots actually differ.

- **Two Claude accounts no longer interfere with each other's backoff or profile cache.** [#235](https://github.com/Nanako0129/TokenBar/pull/235)

  A single shared rate-limit cooldown meant one account clearing it lifted it for the other, and a single shared profile entry collapsed its one-hour lifetime into a fetch on every poll. Both are now per account. Single-account users are unaffected.

- **A count of zero is no longer shown where nothing was counted.** [#227](https://github.com/Nanako0129/TokenBar/pull/227)

  A source that reports a price with no token counts rendered as a measured `0` beside a real dollar amount — in the quota history rows, in their expanded per-model rows, and in the subscription trend under its token metric. A missing measurement now reads as missing. The same rule already applied to prices in the other direction and was stated in one place per column; it is now stated once for both.
