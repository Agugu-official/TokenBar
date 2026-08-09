## Before you update

**Pace history restarts once.** Affected quota cards show "Learning history · Linear estimate" again and rebuild their curve — a short window within hours, a weekly one over a few days. Nothing is broken; this is the one-time cost of the identity fix below, and it does not repeat.

Which cards depends on whether the provider gives TokenBar a stable account identifier, not on the provider's name:

| Keeps its history | Starts over |
|---|---|
| Codex, when its stored credential carries an account ID | Claude, on every login route |
| The Antigravity IDE | Grok, Copilot, and Antigravity's remote login |
| | Codex, if its credential has no account ID |

## Fixes

- **Pace history no longer restarts every time another app refreshes a shared login.** [#204](https://github.com/Nanako0129/TokenBar/pull/204)

  Providers without a stable account identifier keyed their history on a fingerprint of the OAuth refresh token. When a sibling application rotated that token — the Claude CLI refreshing its own Keychain item, for instance — TokenBar saw a credential it did not recognise and began learning from zero. On one machine this had produced 17 separate series holding 1,007 unreachable samples for a single Claude account, and Historical pace could never accumulate.

  Durable history now has its own identity, separate from the one used for caching. Where a provider exposes a stable account ID it is still used, so Codex and the Antigravity IDE keep their per-account separation. Where none exists, history is now keyed per installation, which means two accounts on one machine share one curve on those providers. That is deliberate: the curve describes how a person consumes a window, which belongs to the operator rather than to the billing account.

- **A pace marker in deficit is highlighted whichever estimator produced it.** [#205](https://github.com/Nanako0129/TokenBar/pull/205)

  Only a historical result was coloured before, so a linear estimate sitting in deficit looked identical to one on track. Because the historical fit is re-evaluated on every refresh, the warning appeared and vanished while the deficit underneath never moved. The colour now follows the gap; the status text still says which estimator drew the line.

- **A clock disagreement no longer discards the whole quota history.** [#206](https://github.com/Nanako0129/TokenBar/pull/206)

  A single forward jump of the system clock — a time sync, or a sleep and wake — was latched permanently into a window's timestamps. Once the clock settled back, every later read saw a value from the future and quarantined the entire store, taking every provider's history with it. One report lost 585 samples and three weeks of evidence this way, with every other invariant intact.

  Such a store is now repaired in place instead of being discarded, and only a window whose own recorded observations cannot be verified is dropped. Structurally damaged files are still quarantined exactly as before. Reported by [@starburst3190](https://github.com/starburst3190) with the quarantined file's timestamps isolated to the single failing invariant, which is what made the cause findable. [#144](https://github.com/Nanako0129/TokenBar/issues/144)

## Changes

- Updater: the bundled Sparkle framework is now compiled from source as part of the build. [#208](https://github.com/Nanako0129/TokenBar/pull/208)
