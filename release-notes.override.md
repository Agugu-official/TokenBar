## Fixes

- **The quota equivalence counted fewer tokens than it priced.** [#238](https://github.com/Nanako0129/TokenBar/pull/238)

  The estimate under a quota window — and the heatmap tooltip that scales from it — print a token count beside a dollar amount as two descriptions of the same work. A reader divides them. The count excluded cache reads while the amount included their cost, so the quotient came out several times any model's list rate.

  Reported from a live reading: `72 quota points ~ 4.8M · $172.25`, which is **$36 per million**. Cache reads are most of the volume in a Claude Code session, so most of the tokens were missing from the count while all of their cost remained in the price.

  The count now covers what the price covers. **The dollar figure does not move** — it was never the wrong half. The token figure grows, and the implied per-million rate falls back near list.

  The direction was forced rather than chosen: a message carries one cost, not one per token class, so the price cannot be narrowed to match a smaller count. Widening the count was the only consistent pairing available.

  Both surfaces are corrected together. The estimate is computed in two places — once for the live window and once for the pooled history, rendered one above the other — and fixing only the second would have put the old number and the new one on screen at the same time. [#237](https://github.com/Nanako0129/TokenBar/issues/237)
