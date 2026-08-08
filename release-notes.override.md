## Highlights

- **Discord Rich Presence.** TokenBar can publish what you are working on to Discord. It is off by default. The usage details are yours to choose — tokens, the agent, the cost band, any combination or none — and you can name which agent is published rather than whichever happens to be busiest, so the presence does not jump around while you work. Cost is published as a logarithmic band; a whole-dollar figure is available separately and opt-in. Everything else in a presence is fixed: it always carries TokenBar's own name and icon, and a button linking to this repository. [#142](https://github.com/Nanako0129/TokenBar/pull/142) [#143](https://github.com/Nanako0129/TokenBar/pull/143) [#145](https://github.com/Nanako0129/TokenBar/pull/145) [#146](https://github.com/Nanako0129/TokenBar/pull/146) [#184](https://github.com/Nanako0129/TokenBar/pull/184) [#185](https://github.com/Nanako0129/TokenBar/pull/185)
- **The dashboard opens faster and stops being blank.** Opening the popover used to dispatch three full scans at once — the chart, the model report, and a third whose only job was counting turns — on a two-thread pool, doubling the total work and delaying the first thing you see. Now the chart runs alone and renders as soon as it is ready, turn counts ride along in its own pass, and restarting restores the last dashboard immediately while a refresh runs behind it. [#187](https://github.com/Nanako0129/TokenBar/pull/187) [#192](https://github.com/Nanako0129/TokenBar/pull/192)
- **Scanning itself is about a third faster.** The Claude and Codex parsing lanes now process files in batches, parsing cache misses in parallel while message ordering and deduplication stay strictly serial. Measured against the engine v1.12.0 shipped, on a frozen 8 GB corpus of 171,984 messages, four alternating pairs with a cooldown before every run: cold scan 28.4 s to **19.3 s (−31%)**, warm scan 3.3 s to **2.3 s (−37%)**, peak memory **+15%**. Every pair improved on both, the weakest cold pair by −29% and the weakest warm pair by −24%. Memory is the trade: batching holds more in flight, though a cache hit returns a marker instead of copying the cached messages, which bounds the increase to files that actually need parsing. [#195](https://github.com/Nanako0129/TokenBar/pull/195)

## Changes

- Quota figures are deliberately not written to disk, since they carry account identity. After a restart those rows read "Checking…" until the first live answer arrives, rather than claiming there is no data — "no data" is a claim that we asked and there was none. [#192](https://github.com/Nanako0129/TokenBar/pull/192)
- The refresh button doubles as the freshness indicator, so a restored dashboard is distinguishable from a live one at a glance. [#192](https://github.com/Nanako0129/TokenBar/pull/192)
- Hovering a heatmap cell rings it, matching the bar chart. [#141](https://github.com/Nanako0129/TokenBar/pull/141)

## Fixes

- **Turns dropped by an in-place transcript rewrite are recovered.** When a transcript was rewritten in place — during compaction, for instance — the turns removed from the file used to disappear from history as well. Claude totals may therefore be higher after this update. That is the fix, not inflation. [#195](https://github.com/Nanako0129/TokenBar/pull/195)
- **Inactive segments of the view switch are clickable again.** The hit area only covered the active segment, so changing views needed a pixel-accurate click. [#182](https://github.com/Nanako0129/TokenBar/pull/182) — thanks @yeha98555
- Codex shows its monochrome mark instead of the ChatGPT green. [#140](https://github.com/Nanako0129/TokenBar/pull/140)

## Upgrading

The engine's cache format changed, so **the first launch after this update rescans every client once** and will be slower than usual. Later launches are back to normal.

That rescan was sequenced deliberately rather than deferred: the same release recovers turns that an in-place transcript rewrite had dropped, and bumping the cache format afterwards would have discarded the only surviving copy of them.
