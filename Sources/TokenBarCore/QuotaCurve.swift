import Foundation

// Read-only quota curve snapshot (`tb_quota_curve`). Keys match the Rust serde
// camelCase serialization exactly.
//
// The decoding here is deliberately stricter than the JSON shape. This payload
// crosses the C ABI from a producer that already refuses to emit anything but a
// validated series, so every property below is something Rust guarantees rather
// than something this layer hopes for. Accepting a value Rust cannot produce
// would let an ABI drift render as a plausible curve instead of failing closed,
// which is the same contract the pace enums in `AgentUsage.swift` already hold.

/// Where a point's window length came from. Same Rust `DurationSource` wire
/// values as `UsagePaceDurationSource`; kept as a separate type only because the
/// two payloads are decoded independently.
public enum QuotaCurveDurationSource: String, Decodable, Sendable, Equatable {
    case provider
    case contract
    case observed
}

/// Which writer recorded the sample. `importedV2` is the one-time schema-2
/// migration lane; everything recorded by the v3 writer is `liveV3`.
public enum QuotaCurveSampleOrigin: String, Decodable, Sendable, Equatable {
    case liveV3
    case importedV2
}

/// One admitted quota reading. `sampledAt` is the real observation time, never
/// a grid position: phase-bucket admission decides *whether* a reading is kept,
/// not when it was taken, so the points are unevenly spaced by construction.
public struct QuotaCurvePoint: Decodable, Sendable, Equatable {
    public let sampledAt: Int64
    public let usedPercent: Double
    public let resetAt: Int64
    /// Per point, not per cycle: one reset group can legitimately carry
    /// readings recorded under different window lengths and sources.
    public let durationSeconds: Int64
    public let durationSource: QuotaCurveDurationSource
    public let origin: QuotaCurveSampleOrigin

    private enum CodingKeys: String, CodingKey {
        case sampledAt, usedPercent, resetAt, durationSeconds, durationSource, origin
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sampledAt = try container.decode(Int64.self, forKey: .sampledAt)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        resetAt = try container.decode(Int64.self, forKey: .resetAt)
        durationSeconds = try container.decode(Int64.self, forKey: .durationSeconds)
        durationSource = try container.decode(QuotaCurveDurationSource.self, forKey: .durationSource)
        origin = try container.decode(QuotaCurveSampleOrigin.self, forKey: .origin)

        // Exactly `validate_sample` in agent_quota_history.rs: a sample that
        // fails any of these never enters the store, so seeing one here means
        // the payload did not come from that store.
        guard durationSeconds >= 1 else {
            throw QuotaCurve.corrupted(decoder, "durationSeconds must be positive")
        }
        guard usedPercent.isFinite, usedPercent > 0, usedPercent <= 100 else {
            throw QuotaCurve.corrupted(decoder, "usedPercent must fall in (0, 100]")
        }
        let cycleStart = resetAt.subtractingReportingOverflow(durationSeconds)
        guard !cycleStart.overflow, (cycleStart.partialValue...resetAt).contains(sampledAt) else {
            throw QuotaCurve.corrupted(decoder, "sampledAt falls outside its own cycle")
        }
    }
}

/// What the snapshot covers. Deliberately not a completeness claim — whether a
/// requested range is fully covered is decided when drawing, against the
/// series' actual window length and the samples actually held.
public struct QuotaCurveCoverage: Decodable, Sendable, Equatable {
    public let oldestSampledAt: Int64
    public let newestSampledAt: Int64
    public let sampleCount: Int
}

public struct QuotaCurve: Decodable, Sendable, Equatable {
    public let points: [QuotaCurvePoint]
    public let coverage: QuotaCurveCoverage
    public let activeResetAt: Int64?
    /// The publication generation whose binding resolved this series' identity.
    /// It is not a data cutoff: the samples are the history as of the read.
    public let generation: UInt64

    private enum CodingKeys: String, CodingKey {
        case points, coverage, activeResetAt, generation
    }

    static func corrupted(_ decoder: Decoder, _ description: String) -> DecodingError {
        DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath, debugDescription: description))
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        points = try container.decode([QuotaCurvePoint].self, forKey: .points)
        coverage = try container.decode(QuotaCurveCoverage.self, forKey: .coverage)
        activeResetAt = try container.decodeIfPresent(Int64.self, forKey: .activeResetAt)
        generation = try container.decode(UInt64.self, forKey: .generation)

        // Absent history is `null`, never an empty curve: the producer returns
        // early when the series holds no samples, and `quota_curve_payload`
        // errors rather than emitting a coverage window it cannot derive.
        guard let first = points.first, let last = points.last else {
            throw Self.corrupted(decoder, "a curve with no points must be serialized as null")
        }

        // Rust sorts the samples and then takes coverage from the ends of that
        // same vector, so these are equalities rather than bounds checks.
        guard coverage.sampleCount == points.count else {
            throw Self.corrupted(decoder, "coverage.sampleCount disagrees with points")
        }
        guard coverage.oldestSampledAt == first.sampledAt,
              coverage.newestSampledAt == last.sampledAt
        else {
            throw Self.corrupted(decoder, "coverage does not match the points it covers")
        }
        guard zip(points, points.dropFirst()).allSatisfy({ $0.sampledAt <= $1.sampledAt }) else {
            throw Self.corrupted(decoder, "points are not ordered by sampledAt")
        }
    }
}
