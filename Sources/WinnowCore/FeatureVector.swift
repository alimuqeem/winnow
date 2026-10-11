import Accelerate
import Foundation

/// A Vision image feature print (768 unit-length floats on macOS 26+).
///
/// Vision's `distance(to:)` is the *squared* Euclidean distance; for unit
/// vectors that is `2 - 2·dot`, which is what we compute here so cached
/// vectors can be compared without re-hydrating Vision observations.
public struct FeatureVector: Sendable, Hashable {
    public let values: [Float]

    public init(_ values: [Float]) { self.values = values }

    public init(data: Data) {
        values = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    public var data: Data { values.withUnsafeBufferPointer { Data(buffer: $0) } }

    public func distance(to other: FeatureVector) -> Float {
        guard values.count == other.values.count, !values.isEmpty else { return .infinity }
        return max(0, 2 - 2 * vDSP.dot(values, other.values))
    }
}

/// Similarity tolerance in Vision squared-distance units (256 px prints).
///
/// Calibrated 2026-10-11 on sample pairs from a 104k-photo library:
/// ≤ 0.10 duplicates/bursts · 0.10–0.22 same shot reframed ·
/// 0.25–0.34 same moment, different pose/angle · > 0.35 different shots
/// that merely share people or place (not useful to group).
public enum Tolerance {
    public static let range: ClosedRange<Float> = 0.02...0.45
    /// Edges are cached up to this distance, so the slider never needs a rescan.
    public static let maxThreshold: Float = range.upperBound

    public enum Preset: String, CaseIterable, Sendable, Identifiable {
        case nearIdentical = "Near-identical"
        case similar = "Similar"
        case sameMoment = "Same moment"

        public var id: String { rawValue }
        public var threshold: Float {
            switch self {
            case .nearIdentical: 0.08
            case .similar: 0.20
            case .sameMoment: 0.35
            }
        }
    }

    /// Default comparison window and the cap on a group's time span.
    public static let timeWindow: TimeInterval = 10 * 60
    public static let maxGroupSpan: TimeInterval = 30 * 60
}
