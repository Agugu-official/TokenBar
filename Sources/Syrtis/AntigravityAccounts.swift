import Foundation
import TokenBarCore

/// Captured Antigravity accounts: extra Google logins copied from agy, each
/// fetched as its own Antigravity card after the primary.
///
/// UserDefaults holds only `{key, label}` per account. The credential lives in
/// a login-keychain item the core owns (`tb_antigravity_capture`), and the key
/// is a hash of the Google account id, never shown: every label surface goes
/// through `AccountIdentity.accountLabel`, which resolves the key here.
///
/// The core registry is in-memory and starts empty every launch, so the app
/// installs this list at launch and after every change, the same as
/// `ClaudeExtraRoots` and `GrokBotKeychainConsent`.
enum AntigravityAccounts {
    struct Account: Codable, Equatable, Sendable {
        let key: String
        let label: String
    }

    static let storageKey = "tokenbar.antigravity.accounts"

    static func load(defaults: UserDefaults = .standard) -> [Account] {
        guard let raw = defaults.string(forKey: storageKey),
              let accounts = try? JSONDecoder().decode([Account].self, from: Data(raw.utf8))
        else { return [] }
        return accounts
    }

    static func save(_ accounts: [Account], defaults: UserDefaults = .standard) {
        defaults.set(payloadJSON(accounts), forKey: storageKey)
    }

    /// The stored list is also the `tb_set_antigravity_accounts` payload.
    static func payloadJSON(_ accounts: [Account]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(accounts)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    /// The registry's label for `key`, or nil when the key is not listed.
    static func label(for key: String, defaults: UserDefaults = .standard) -> String? {
        load(defaults: defaults).first { $0.key == key }?.label
    }

    /// Point `AccountIdentity.accountLabel` at this registry. Called at launch;
    /// the selftest passes its own suite.
    static func installLabelResolver(defaults: UserDefaults = .standard) {
        // UserDefaults is documented thread-safe; it is just not marked Sendable.
        nonisolated(unsafe) let defaults = defaults
        AccountIdentity.antigravityLabel = { label(for: $0, defaults: defaults) }
    }

    /// Install the stored list in the core and, when it differs from what this
    /// process installed last, wake the quota pollers so the cards follow.
    static func apply(defaults: UserDefaults = .standard) {
        let payload = payloadJSON(load(defaults: defaults))
        applyQueue.async {
            // The core starts empty each launch, so "nothing installed yet"
            // compares as `[]`: an empty list at launch costs no wake, and a
            // non-empty one wakes the launch poll that may have raced it.
            guard payload != (lastInstalledPayload ?? payloadJSON([])) else {
                lastInstalledPayload = payload
                return
            }
            lastInstalledPayload = payload
            _ = try? TBCore.setAntigravityAccounts(json: payload)
            Task { @MainActor in
                // Invalidate before signalling, as `ClaudeExtraRoots.install`
                // does: a woken poll must not be answered from the throttled
                // payload built for the previous account set.
                await AgentUsageThrottle.shared.invalidate()
                ClaudeExtraRoots.RegistryChange.signal()
            }
        }
    }

    private static let applyQueue = DispatchQueue(
        label: "com.nyanako.tokenbar.antigravity-accounts", qos: .userInitiated)
    /// Touched only on `applyQueue`.
    nonisolated(unsafe) private static var lastInstalledPayload: String?

    /// Capture agy's current login. Blocking work (a `security` child and a
    /// request to Google) runs on a detached task, never the main actor.
    static func capture() async -> Result<AntigravityCapturedAccount, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try TBCore.antigravityCapture() }
        }.value
    }

    /// Delete one account's keychain copy, off the main actor.
    static func remove(key: String) async -> Result<Void, Error> {
        await Task.detached(priority: .userInitiated) {
            Result { try TBCore.antigravityRemove(key: key) }
        }.value
    }

    /// `accounts` with `captured` added, or its label refreshed when the same
    /// Google account was captured before.
    static func adding(_ captured: Account, to accounts: [Account]) -> [Account] {
        guard let index = accounts.firstIndex(where: { $0.key == captured.key }) else {
            return accounts + [captured]
        }
        var updated = accounts
        updated[index] = captured
        return updated
    }

    /// A short sentence for a capture or remove failure. The core's error is a
    /// fixed code naming no account; it is mapped here and never shown raw.
    static func message(for error: Error) -> String {
        guard case let TBCoreError.bridge(code) = error else {
            return "Something went wrong. Try again."
        }
        switch code {
        case "agy_not_signed_in":
            return "Couldn't read agy's login. Check that agy is signed in, and allow access if macOS asks."
        case "agy_login_unreadable":
            return "agy's saved login is in a format Syrtis doesn't recognize."
        case "agy_login_missing_identity":
            return "agy's saved login doesn't say which Google account it is. Sign agy in again, then try again."
        case "oauth_client_not_found":
            return "Couldn't match this login to the installed Antigravity or agy."
        case "oauth_client_rejected", "refresh_rejected":
            return "Google didn't accept this login. Sign agy in again, then try again."
        case "refresh_unreachable":
            return "Google couldn't be reached right now. Try again later."
        case "account_mismatch":
            return "Google answered for a different account. Nothing was saved."
        case "invalid_credential_format":
            return "The login had an unexpected format. Nothing was saved."
        case "keychain_write_failed":
            return "Couldn't save to the login keychain."
        case "keychain_delete_failed":
            return "Couldn't delete the copy from the login keychain."
        default:
            return "Something went wrong. Try again."
        }
    }
}
