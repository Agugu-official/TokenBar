import Foundation
import TokenBarCore

/// Persisted list of extra Claude config dirs the user configured for a
/// second (or further) `CLAUDE_CONFIG_DIR`-isolated account. Each entry
/// expands to the two sub-roots the engine actually scans for the primary
/// account — `<dir>/projects` and `<dir>/transcripts` (D2 in the extra-root
/// plan) — and is pushed to the Rust registry via `TBCore.setExtraScanPaths`.
///
/// Usage from these roots merges into the single reported total; there is no
/// per-account breakdown. Settings must say so explicitly (see
/// `SettingsPanel`'s hint copy) so a user adding a second account does not
/// expect a split view that does not exist.
enum ClaudeExtraRoots {
    static let storageKey = "tokenbar.claude.extraConfigDirs"
    /// Incremented once the core has accepted a new root set. Views observe
    /// THIS rather than `storageKey` when they need to reload against the new
    /// roots — see `apply`.
    static let generationKey = "tokenbar.claude.extraRootsGeneration"

    static func load() -> [String] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
            let data = raw.data(using: .utf8),
            let paths = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return paths
    }

    static func save(_ paths: [String]) {
        let data = (try? JSONEncoder().encode(paths)) ?? Data("[]".utf8)
        UserDefaults.standard.set(String(data: data, encoding: .utf8) ?? "[]", forKey: storageKey)
    }

    /// A config dir is missing right now (external drive unmounted, typo,
    /// etc). Kept in the list either way — an unmounted volume must not
    /// silently drop the user's setting the way vendor's own scan does for
    /// paths that vanish mid-session; the difference is Settings can *show*
    /// the warning, where a background scan has nowhere to show it.
    ///
    /// Blocking: `fileExists` stats the path, which on a stalled network or
    /// external mount takes as long as the mount takes to time out. Call it
    /// off the main actor — `missingRoots(in:then:)` is the wrapper Settings
    /// uses.
    static func isMissing(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return !exists || !isDir.boolValue
    }

    /// Reject the home directory itself and the filesystem root outright —
    /// anything else is the user's call (mirrors the plan's risk table: the
    /// core only warns on an out-of-home path, it does not block).
    static func isRejectedRoot(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return standardized.isEmpty || standardized == "/" || standardized == home
    }

    /// Expand a user-entered `CLAUDE_CONFIG_DIR` into the two sub-roots the
    /// engine scans for the primary `$HOME/.claude` root (`clients.rs:187`,
    /// `scanner.rs:443`) — requiring only one sub-path here would leave the
    /// other silently missing whenever a real isolated dir produces it.
    static func expand(_ configDir: String) -> [String] {
        let base = (configDir as NSString).standardizingPath
        return ["\(base)/projects", "\(base)/transcripts"]
    }

    /// Build the `tb_set_extra_scan_paths` payload from the persisted list:
    /// `{"claude": [path, path, ...]}`, expanded and deduplicated. One call
    /// covers every configured dir — full-replace semantics, so an empty
    /// list clears the registry (the Settings rollback path).
    static func payloadJSON(_ configDirs: [String]) -> String {
        var seen = Set<String>()
        let expanded = configDirs.flatMap(expand).filter { seen.insert($0).inserted }
        let object = ["claude": expanded]
        let data = (try? JSONEncoder().encode(object)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// The `tb_set_claude_config_dirs` payload: the configured directories
    /// themselves, standardized, as a JSON array.
    ///
    /// Deliberately built from `load()` — the list the user configured — and
    /// not from `appliedPayloadJSON`, the scan subset the core accepted. They
    /// answer different questions: a directory the scanner refuses is still a
    /// perfectly valid account whose Keychain item holds real credentials, and
    /// `appliedKey` is empty until the launch-time apply lands, which is an
    /// honest answer about scanning and a wrong one about identity.
    ///
    /// Standardized with the same `standardizingPath` `expand` uses, because
    /// the Keychain service the core derives is the SHA-256 of this exact
    /// string: `/x/.claude-work/` and `/x/.claude-work` would read different
    /// items, and only one of them exists.
    static func configDirsPayloadJSON(_ configDirs: [String]) -> String {
        var seen = Set<String>()
        let standardized = configDirs
            .map { ($0 as NSString).standardizingPath }
            .filter { seen.insert($0).inserted }
        let data = (try? JSONEncoder().encode(standardized)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// Which of `paths` are missing right now, resolved off the calling actor.
    ///
    /// Settings renders a warning icon per row, and doing that from `isMissing`
    /// during view construction meant a `stat` per row on the main actor, on
    /// every render — the same stall as the setter, on the same kind of path,
    /// for a feature whose whole point is tolerating roots that are
    /// temporarily unreachable.
    ///
    /// Shares `applyQueue` with `apply`, so a probe issued after a save
    /// observes the registry that save produced rather than racing it.
    static func missingRoots(
        in paths: [String],
        then completion: @escaping @Sendable @MainActor (Set<String>) -> Void
    ) {
        applyQueue.async {
            let missing = Set(paths.filter(isMissing))
            Task { @MainActor in completion(missing) }
        }
    }

    /// Which scan roots the engine is running — the registry it ACCEPTED, not
    /// the list the user configured, and not two values that have to be kept
    /// in step.
    ///
    /// One persisted string. `apply` deliberately keeps the setter off the
    /// calling actor (the core probes each path with `read_dir`, and an
    /// unmounted volume can stall that — the case this feature exists to
    /// tolerate), so `load()` names the new roots while the engine still scans
    /// the old ones. And a call that SUCCEEDS can still refuse part of its
    /// input: `rejected` names paths Rust left out of the registry, so
    /// recording the request would claim roots no scan included. `unreadable`
    /// is the opposite case and stays — those ARE registered and retried.
    ///
    /// Persisted rather than held in memory, because the value a RESTORE needs
    /// is the registry the file on disk was written under, and that restore
    /// runs before this launch's apply has landed. Persisting one value answers
    /// both questions with the same number instead of an in-memory copy for
    /// stamping and a stored copy for validating.
    ///
    /// It moves the moment an apply succeeds while the snapshot is only
    /// rewritten by the next graph commit, so a root change followed by a quit
    /// leaves this ahead of the file and the file is rejected. That direction
    /// is the safe one: a false reject costs one cold start, a false accept
    /// shows the wrong totals.
    static let appliedKey = "tokenbar.claude.extraRootsApplied"

    /// Overridable so a self-test can move the roots DURING a fetch — the
    /// property under test — without writing the real defaults key.
    nonisolated(unsafe) static var appliedProvider: @Sendable () -> String = {
        UserDefaults.standard.string(forKey: appliedKey) ?? payloadJSON([])
    }

    static var appliedPayloadJSON: String { appliedProvider() }

    /// Record what the setter actually installed. A failed call leaves the
    /// registry holding whatever it held, so the stored value must not move.
    static func recordApplied(_ requestedJSON: String, result: ExtraScanPathsResult?) {
        guard let result else { return }
        UserDefaults.standard.set(
            registeredJSON(requestedJSON, rejected: result.rejected), forKey: appliedKey)
    }

    /// `requestedJSON` minus the paths the setter refused, in the same shape.
    ///
    /// Returns the input untouched when nothing was refused, so the common case
    /// is byte-identical to `payloadJSON(load())` and no comparison drifts on
    /// re-encoding. A payload this cannot parse is also returned untouched: it
    /// came from `payloadJSON` one line earlier, so failing to parse it is
    /// impossible in practice, and guessing would be worse than recording the
    /// request.
    static func registeredJSON(_ requestedJSON: String, rejected: [ScanPathNote]) -> String {
        let refused = Set(rejected.map(\.path))
        guard !refused.isEmpty,
              let data = requestedJSON.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return requestedJSON }
        let kept = object.mapValues { paths in paths.filter { !refused.contains($0) } }
        guard let encoded = try? JSONEncoder().encode(kept),
              let text = String(data: encoded, encoding: .utf8)
        else { return requestedJSON }
        return text
    }

    /// Test seam only: back to the pre-apply state.
    static func resetAppliedForTesting() {
        appliedProvider = { UserDefaults.standard.string(forKey: appliedKey) ?? payloadJSON([]) }
        UserDefaults.standard.removeObject(forKey: appliedKey)
    }

    /// Wakes anything sleeping between polls when the installed account
    /// registry moves.
    ///
    /// The quota cards come from a 60-second poll loop, so adding or removing
    /// an account left the cards describing the previous set until that loop
    /// happened to come round. Keying a view's `.task` on the generation fixed
    /// it only while that view was alive — with the popover closed, or the
    /// separate Settings window in use, nothing was observing. The registry is
    /// process-wide state, so what waits on it has to be too.
    @MainActor
    enum RegistryChange {
        /// Advanced by every `signal()`. A caller records it BEFORE the work it
        /// might be interrupted during, and passes it back to `sleep` — so a
        /// change that lands while that caller was busy is not lost.
        ///
        /// The first version had no epoch and dropped a signal that arrived
        /// with nobody waiting, which its own comment described as harmless.
        /// It is not: the quota poll spends most of each cycle inside a network
        /// fetch, so removing an account almost always signalled while the loop
        /// was busy. The signal went nowhere, the in-flight fetch published a
        /// payload built from the registry as it was before the removal, and
        /// the card stayed for the full sixty seconds — the exact symptom this
        /// was written to fix.
        private(set) static var epoch = 0
        private static var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

        /// Sleeps for `seconds`, or until the registry moves, whichever first.
        ///
        /// The timeout resumes ITS OWN waiter rather than calling `signal()`.
        /// Routing it through `signal()` read as economical and made the
        /// timeout depend on the wake-up path working: a mutation that stopped
        /// `signal()` resuming anyone did not fail the test, it hung the sleep
        /// forever — a worse outcome than the sixty-second wait this exists to
        /// remove, and in the poll loop that owns the quota cards.
        ///
        /// Registration cannot lose a race with the timeout. Both run on the
        /// MainActor, and `withCheckedContinuation`'s body runs synchronously
        /// before the suspension, so the entry is in the map before the timeout
        /// task can get a turn.
        static func sleep(upTo seconds: Double, since observed: Int) async {
            // Already stale: the registry moved while the caller was working,
            // so there is nothing to wait for and the next fetch is owed now.
            guard observed == epoch else { return }
            let id = UUID()
            let timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                resume(id)
            }
            await withCheckedContinuation { waiters[id] = $0 }
            timeout.cancel()
        }

        private static func resume(_ id: UUID) {
            waiters.removeValue(forKey: id)?.resume()
        }

        /// Releases every waiter. Idempotent: a change with nobody waiting is
        /// not an error, and a second call before anyone sleeps again is a
        /// no-op rather than a queued wake-up that would fire spuriously.
        static func signal() {
            epoch &+= 1
            let pending = waiters
            waiters.removeAll()
            for (_, waiter) in pending { waiter.resume() }
        }
    }

    private static let applyQueue = DispatchQueue(
        label: "com.nyanako.tokenbar.claude-extra-roots", qos: .utility)

    /// Push the persisted config dirs to the Rust registry. Call at launch
    /// and after every add/remove so the change takes effect without an app
    /// restart (D1). Failures are logged by `TBCore`, not thrown further — a
    /// bridge failure here must not block the rest of app startup or a
    /// Settings edit.
    ///
    /// **Never runs the setter on the calling actor.** The core probes every
    /// configured path with `read_dir`, and an unmounted external volume or a
    /// stalled network mount can block that syscall for a long time — which is
    /// precisely the case this feature exists to tolerate. Doing it inline
    /// would freeze launch or the Settings window in the exact scenario the
    /// keep-and-retry behavior was built for, so the probe goes to a utility
    /// queue and only the result comes back to the main actor.
    ///
    /// Reading UserDefaults stays on the caller: it is cheap, and hopping with
    /// an already-serialized payload keeps the background block from touching
    /// app state at all.
    ///
    /// Serial, not `DispatchQueue.global()`: each call replaces the whole
    /// registry, so two applies racing — Settings removing two rows in quick
    /// succession — could finish in either order on a concurrent queue and
    /// leave the core scanning a list UserDefaults no longer holds, silently,
    /// since neither side reports an error. Serial means the last save is
    /// also the last registered.
    static func apply(
        then completion: (@Sendable @MainActor (ExtraScanPathsResult?) -> Void)? = nil
    ) {
        let configDirs = load()
        let json = payloadJSON(configDirs)
        let configDirsJSON = configDirsPayloadJSON(configDirs)
        applyQueue.async {
            // The quota-card registry, from the configured list. Separate call
            // and separate registry from the scan roots below: this one decides
            // whose credential each Claude card is fetched with, and a failure
            // in either must not stop the other from being installed.
            _ = try? TBCore.setClaudeConfigDirs(json: configDirsJSON)
            let result = try? TBCore.setExtraScanPaths(json: json)
            Task { @MainActor in
                // Before the invalidation and the generation bump, so anything
                // they restart reads the registry that is now installed rather
                // than the one it replaced.
                recordApplied(json, result: result)
                // The engine dropped its own caches inside the setter. These
                // are the Swift ones, which answer without asking it — see
                // `invalidateScanDerivedCaches`. Unconditional on `completion`,
                // because whether a caller wants to hear about the result says
                // nothing about whether the caches went stale.
                DashboardModel.invalidateScanDerivedCaches()
                // Bumped AFTER the setter returns, and this is what views key
                // their reloads on — not the persisted list. The list changes
                // the moment Settings saves, which is before this queue has
                // installed anything, so a task keyed on it can restart, run,
                // and publish while the engine is still scanning the old roots.
                // A generation moved here cannot fire early by construction.
                UserDefaults.standard.set(
                    UserDefaults.standard.integer(forKey: generationKey) &+ 1,
                    forKey: generationKey)
                // And wake the polls directly. The generation only reaches a
                // view that is on screen; this reaches the loop that owns the
                // cards whether or not anything is watching.
                RegistryChange.signal()
                // And drop the throttled payload. Waking the poll is not
                // enough on its own: the fetch it wakes into is answered from
                // `AgentUsageThrottle`'s 50-second floor, which would hand back
                // the payload built for the account set that just changed.
                Task { await AgentUsageThrottle.shared.invalidate() }
                completion?(result)
            }
        }
    }
}
