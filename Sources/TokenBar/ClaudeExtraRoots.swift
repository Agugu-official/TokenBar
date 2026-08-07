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

    /// Push the persisted config dirs to the Rust registry. Call at launch
    /// (before the first scan) and after every add/remove so the change
    /// takes effect without an app restart (D1). Failures are logged by
    /// `TBCore`, not thrown further — a bridge failure here must not block
    /// the rest of app startup or a Settings edit.
    @discardableResult
    static func apply() -> ExtraScanPathsResult? {
        try? TBCore.setExtraScanPaths(json: payloadJSON(load()))
    }
}
