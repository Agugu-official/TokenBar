## Before you update

**Five clients rescan once.** Amp, Cursor, OpenClaw, MiMoCode, and Mux advance to a new parser identity in this engine update, so their cached shards are rebuilt cold on the first refresh after installing. Expect one slower scan for those clients and nothing else; other clients keep their cache.

## Fixes

- **A Claude credential store that holds no login no longer blocks the setup-token fallback.** [#221](https://github.com/Nanako0129/TokenBar/pull/221)

  The Claude card could sit permanently on "Claude credentials could not be loaded." while the documented `tokenbar-claude-oauth-token` Keychain path was never even read, so following the in-app instructions changed nothing. The cause was a `Claude Code-credentials` Keychain item that existed but carried no `claudeAiOauth` key — on the reporting machine it held only `mcpOAuth`, an MCP server's OAuth data written into the same item. TokenBar read that as a credential it could not parse and failed closed, which by design skips the setup-token fallback.

  A store with no `claudeAiOauth` key is now treated as absence rather than damage, so the setup-token route is tried and, with no token stored, the card shows the setup prompt instead of an error. Genuinely malformed credentials still fail closed, and a Keychain item holding no login still does not fall through to `~/.claude/.credentials.json` — that fall-through was written and then dropped, because if the shape turns out to be what Claude Code leaves behind after a logout, falling through would silently resume a stale token and keep refreshing it. Reported by [@coshsh1991](https://github.com/coshsh1991) with the failing resolution traced to the exact line, which is what made it a direct fix rather than a hunt. [#219](https://github.com/Nanako0129/TokenBar/issues/219)

- **Manual refresh now retries a model report that failed.** [#214](https://github.com/Nanako0129/TokenBar/pull/214)

  The Refresh button and Command-R refreshed the graph and any loaded Hourly or Agents report, but stopped short of the model report. A transient failure therefore stayed on screen until the next 60-second poll, including immediately after the user had explicitly asked for fresh data. The retry cannot key on an empty report, because a failed request keeps the last good one visible while the graph moves on; it keys on the report being stale for the committed slice. Dashboards that never asked for a model report still perform no scan.

- **Reopening the popover no longer shows the previous window's data.** [#213](https://github.com/Nanako0129/TokenBar/pull/213)

  Closing the popover during a scan left the retiring view able to finish and write its result into the shared reopen cache — after the next popover had already committed something newer. The next open then rendered the older payload. The newest view now owns that cache, and both the snapshot and live-data paths check ownership before writing. A retiring view still completes and updates its own state, so switching lenses is unaffected.

- **Sources with no usage are no longer offered for classification.** [#211](https://github.com/Nanako0129/TokenBar/pull/211)

  Usage attribution built a row for every observed source key, including keys with nothing behind them, so a row reading `0 tokens · $0.00` asked which subscription had paid for nothing. A range whose sources are all empty now reads as "No provider-split usage in this range." instead of presenting decisions that cannot matter. A row with zero tokens but non-zero cost is kept — that is spend, however it arrived.

## Changes

- **Three client names no longer claim a surface their data does not distinguish.** [#210](https://github.com/Nanako0129/TokenBar/pull/210)

  | Was | Now |
  |---|---|
  | Codex CLI | Codex |
  | Copilot CLI | Copilot |
  | Cursor IDE | Cursor |

  Each name promised a scope the underlying source cannot support. The `codex` card reads `~/.codex/sessions`, which every Codex surface writes to: across 1,733 local session files, the actual CLI accounted for roughly 4% of what the card was labelling "Codex CLI", behind Codex Desktop at 1,218 files. The `copilot` card merges two parsers covering the CLI, VS Code Copilot Chat, and the macOS desktop app. The `cursor` card is not a session parser at all — it reads an account usage export in which IDE, `cursor-agent`, and cloud-agent spend arrive in one undifferentiated ledger. Names that are genuinely surface-scoped were left alone.

- **Usage attribution now says that some clients merge related routes before the page sees them.** [#211](https://github.com/Nanako0129/TokenBar/pull/211)

  The page explained that provider IDs are compared exactly as the source emitted them, so related-looking routes may appear as separate rows and be classified independently. That is true, and it was the only half being told. Some clients merge those routes before reporting — Vertex AI arriving as Anthropic, Codex as OpenAI — and a row that arrived already merged cannot be split here, however it is classified. Whether a given row is affected depends on the client that produced it, not on the provider's name. The hint now carries both halves.

- **Engine update.** [#217](https://github.com/Nanako0129/TokenBar/pull/217)

  The shared usage engine advances to a reviewed revision carrying local-first graph pricing, embedded and partial cost provenance, message-only coverage, Trae pricing, and preservation of Kilo's provider-reported cost. This is a pin-only update: no change to the cache format, the FFI boundary, or how results are decoded.
