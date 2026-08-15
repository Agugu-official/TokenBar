import Foundation
import TokenBarCore

/// App-level source of usage data. Every usage consumer depends on this
/// contract so `--demo` can replace the complete usage surface without
/// allowing live FFI calls to leak into the demo path.
protocol UsageDataSource: Sendable {
    /// Whether this source may read/write the persistent last-good quota cache.
    var allowsQuotaCachePersistence: Bool { get }

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload
    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload
    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport
    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport
    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport
    func agentUsage() async throws -> AgentUsagePayload
    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket]
    func tokensPerMin() async throws -> Double
    func windowUsage(from: Int64, until: Int64) async throws -> WindowUsage
    func quotaCurve(
        clientId: String, windowKey: String, generation: UInt64
    ) async throws -> QuotaCurve?
    /// Synchronous because it is a ~2ms read of an already-persisted file, and
    /// because the card's first stage must complete without a task hop — an
    /// await here would put the "instant" half behind the scheduler.
    func quotaCurveSync(
        clientId: String, windowKey: String, generation: UInt64
    ) throws -> QuotaCurve?
}

extension UsageDataSource {
    /// Defaulted so the pre-existing test doubles keep compiling. They answer
    /// "no window data", which the card renders as its unavailable state —
    /// asserting the card through a double that predates it would test the
    /// double. The live and demo sources both override.
    func windowUsage(from: Int64, until: Int64) async throws -> WindowUsage {
        WindowUsage(messages: [], undatedCount: 0, processingTimeMs: 0)
    }

    func quotaCurve(
        clientId: String, windowKey: String, generation: UInt64
    ) async throws -> QuotaCurve? { nil }

    func quotaCurveSync(
        clientId: String, windowKey: String, generation: UInt64
    ) throws -> QuotaCurve? { nil }
}

/// The only normal-runtime owner of usage calls into `TBCore`.
struct LiveUsageDataSource: UsageDataSource {
    let allowsQuotaCachePersistence = true

    func windowUsage(from: Int64, until: Int64) async throws -> WindowUsage {
        try await Task.detached(priority: .userInitiated) {
            try TBCore.windowUsage(from: from, until: until)
        }.value
    }

    func quotaCurve(
        clientId: String, windowKey: String, generation: UInt64
    ) async throws -> QuotaCurve? {
        try await Task.detached(priority: .userInitiated) {
            try TBCore.quotaCurve(
                clientId: clientId, windowKey: windowKey, generation: generation)
        }.value
    }

    func quotaCurveSync(
        clientId: String, windowKey: String, generation: UInt64
    ) throws -> QuotaCurve? {
        try TBCore.quotaCurve(
            clientId: clientId, windowKey: windowKey, generation: generation)
    }

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await Task.detached(priority: priority) {
            try TBCore.graph(year: year)
        }.value
    }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        try await Task.detached(priority: priority) {
            try TBCore.refreshGraph(year: year)
        }.value
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        try await Task.detached(priority: priority) {
            try TBCore.modelReport(year: year)
        }.value
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        try await Task.detached(priority: priority) {
            try TBCore.hourlyReport(year: year, clients: clients)
        }.value
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        try await Task.detached(priority: priority) {
            try TBCore.agentsReport(year: year, clients: clients)
        }.value
    }

    func agentUsage() async throws -> AgentUsagePayload {
        try await Task.detached(priority: .utility) {
            try TBCore.agentUsage()
        }.value
    }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        try await Task.detached(priority: .utility) {
            try TBCore.usageTrace(windowSecs: windowSecs)
        }.value
    }

    func tokensPerMin() async throws -> Double {
        try await Task.detached(priority: .utility) {
            try TBCore.tokensPerMin()
        }.value
    }
}

/// Synthetic source used by the hidden `--demo` mode. It only exposes the
/// deterministic fixtures in `DemoData`; it has no dependency on `TBCore`.
struct DemoUsageDataSource: UsageDataSource {
    let allowsQuotaCachePersistence = false

    func graph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = priority
        return DemoData.payload(for: year)
    }

    func refreshGraph(year: String?, priority: TaskPriority) async throws -> UsagePayload {
        _ = priority
        // Rebuild rather than cache the value so manual refresh follows the same
        // source boundary as live refresh and keeps the rolling date current.
        return DemoData.payload(for: year)
    }

    func modelReport(year: String?, priority: TaskPriority) async throws -> ModelReport {
        _ = priority
        return DemoData.modelReport(for: year)
    }

    func hourlyReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> HourlyReport {
        _ = priority
        return DemoData.hourlyReport(for: year, clients: clients)
    }

    func agentsReport(
        year: String?, clients: [String]?, priority: TaskPriority
    ) async throws -> AgentsReport {
        _ = priority
        return DemoData.agentsReport(for: year, clients: clients)
    }

    func agentUsage() async throws -> AgentUsagePayload {
        DemoData.agentUsage
    }

    func usageTrace(windowSecs: Int64) async throws -> [TraceBucket] {
        DemoData.trace(windowSecs: windowSecs)
    }

    func tokensPerMin() async throws -> Double {
        DemoData.tokensPerMin
    }
}

/// Selects one source for the process lifetime. The mode is intentionally
/// launch-time only; changing the flag requires relaunching the app.
enum UsageDataSources {
    static let current: any UsageDataSource = make(arguments: CommandLine.arguments)

    static func make(arguments: [String]) -> any UsageDataSource {
        arguments.contains("--demo") ? DemoUsageDataSource() : LiveUsageDataSource()
    }
}
