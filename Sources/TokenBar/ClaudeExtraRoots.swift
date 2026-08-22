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
        let json = payloadJSON(load())
        applyQueue.async {
            let result = try? TBCore.setExtraScanPaths(json: json)
            Task { @MainActor in
                // The engine dropped its own caches inside the setter. These
                // are the Swift ones, which answer without asking it — see
                // `invalidateScanDerivedCaches`. Unconditional on `completion`,
                // because whether a caller wants to hear about the result says
                // nothing about whether the caches went stale.
                DashboardModel.invalidateScanDerivedCaches()
                completion?(result)
            }
        }
    }
}
