import Foundation

// Provider-based model coloring, ported from the Tauri app's
// src/lib/modelColors.ts (itself ported from tokscale's TUI). Each provider
// has a base color; models within a provider are cost-ranked and tinted
// toward white by rank, so the priciest model reads darkest. Colors are hex
// strings so this stays UI-framework-free.

public enum ModelColors {
    /// Provider base colors (rank-0 / darkest).
    public static let providerBase: [String: String] = [
        "anthropic": "#da7756",
        "openai": "#3b82f6",
        "google": "#06b6d4",
        "cursor": "#a855f7",
        "deepseek": "#4d6bfe",
        "xai": "#1f2937",
        "meta": "#0866ff",
        "mistral": "#fa520f",
        "unknown": "#888888",
    ]

    /// Tint factors toward white by rank — matches tokscale's shade_from_base.
    static let factors: [Double] = [0.0, 0.11, 0.22, 0.33, 0.44, 0.56, 0.67]

    /// Infer a provider key from a model name, mirroring get_provider_from_model.
    public static func providerFromModel(_ model: String) -> String {
        let m = model.lowercased()
        if m.contains("claude") || m.contains("sonnet") || m.contains("opus") || m.contains("haiku") {
            return "anthropic"
        }
        if m.contains("gpt") || m.hasPrefix("o1") || m.hasPrefix("o3") || m.contains("codex")
            || m.contains("text-embedding") || m.contains("dall-e") || m.contains("whisper")
            || m.contains("tts") {
            return "openai"
        }
        if m.contains("gemini") { return "google" }
        if m.contains("deepseek") { return "deepseek" }
        if m.contains("grok") { return "xai" }
        if m.contains("llama") { return "meta" }
        if m.contains("mixtral") || m.contains("mistral") { return "mistral" }
        if m == "auto" || m.contains("cursor") || m.contains("composer") { return "cursor" }
        return "unknown"
    }

    /// Resolve the provider color key: fall back to inferring from the model
    /// when the provider id is empty or a merged list ("litellm, openai").
    public static func providerColorKey(_ providerId: String?, _ modelId: String) -> String {
        let p = (providerId ?? "").lowercased()
        if p.isEmpty || p.contains(", ") { return providerFromModel(modelId) }
        if p.contains("anthropic") { return "anthropic" }
        if p.contains("openai") { return "openai" }
        if p.contains("google") || p.contains("gemini") { return "google" }
        if p.contains("deepseek") { return "deepseek" }
        if p.contains("xai") || p.contains("grok") { return "xai" }
        if p.contains("meta") || p.contains("llama") { return "meta" }
        if p.contains("mistral") { return "mistral" }
        if p.contains("cursor") { return "cursor" }
        if providerBase[p] != nil { return p }
        return providerFromModel(modelId)
    }

    /// Lerp a base hex color toward white by rank.
    public static func shadeFromBase(_ hex: String, rank: Int) -> String {
        let base = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard base.count == 6,
              let r = Int(base.prefix(2), radix: 16),
              let g = Int(base.dropFirst(2).prefix(2), radix: 16),
              let b = Int(base.dropFirst(4).prefix(2), radix: 16)
        else { return hex }
        let f = factors[min(max(rank, 0), factors.count - 1)]
        func lerp(_ c: Int) -> Int { Int((Double(c) + (255.0 - Double(c)) * f).rounded()) }
        return String(format: "#%02x%02x%02x", lerp(r), lerp(g), lerp(b))
    }
}

/// (providerId, modelId) → hex color resolver. Models are cost-ranked within
/// each provider color group; rank drives the shade. Falls back to a rank-0
/// base shade for models not seen at build time.
public struct ModelColorMap: Sendable {
    private let colorByKeyModel: [String: String]

    public init(entries: [(provider: String, model: String, cost: Double)]) {
        // provider key → model → summed cost
        var byProvider: [String: [String: Double]] = [:]
        for e in entries {
            let key = ModelColors.providerColorKey(e.provider, e.model)
            let cost = e.cost.isFinite ? e.cost : 0
            // Grouped on both sides so a raw entry and a raw lookup still meet.
            byProvider[key, default: [:]][ModelGrouping.groupID(e.model), default: 0] += cost
        }
        var map: [String: String] = [:]
        for (providerKey, models) in byProvider {
            let base = ModelColors.providerBase[providerKey] ?? ModelColors.providerBase["unknown"]!
            let ranked = models.sorted { a, b in
                a.value != b.value ? a.value > b.value : a.key < b.key
            }
            for (rank, entry) in ranked.enumerated() {
                map["\(providerKey) \(entry.key)"] = ModelColors.shadeFromBase(base, rank: rank)
            }
        }
        colorByKeyModel = map
    }

    public init(report: ModelReport?) {
        self.init(entries: (report?.entries ?? []).map { ($0.provider, $0.model, $0.cost) })
    }

    /// The table is built from model-report rows, which the engine has already
    /// grouped, while graph and window callers pass raw ids; looking up the
    /// grouped id lets a raw `grok-4.6-build` find the `grok-4.6` shade.
    public func color(_ providerId: String?, _ modelId: String) -> String {
        let key = ModelColors.providerColorKey(providerId, modelId)
        if let hit = colorByKeyModel["\(key) \(ModelGrouping.groupID(modelId))"] { return hit }
        let base = ModelColors.providerBase[key] ?? ModelColors.providerBase["unknown"]!
        return ModelColors.shadeFromBase(base, rank: 0)
    }
}
