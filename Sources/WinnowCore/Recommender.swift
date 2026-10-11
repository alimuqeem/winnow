import Foundation

/// Picks the best asset in a group and decides the default keep set.
/// Formula and tie-breakers: PLAN.md §3 "Quality score". Weights are tuned in Phase 2.
public struct Recommender: Sendable {
    public struct Weights: Sendable, Hashable {
        public var aesthetics = 0.45
        public var sharpness = 0.30
        public var faceQuality = 0.25
        public var utilityPenalty = 0.30
        public init() {}
    }

    public struct Scored: Sendable, Hashable {
        public let id: AssetID
        public let total: Double
        public let aesthetics: Double
        public let sharpness: Double      // normalised within group, 0...1
        public let faceQuality: Double
    }

    public var weights: Weights
    public init(weights: Weights = .init()) { self.weights = weights }

    /// Scores every member; members without signals score 0 and lose ties.
    public func score(_ group: SimilarityGroup, signals: [AssetID: QualitySignals]) -> [Scored] {
        let sharp = group.members.compactMap { signals[$0]?.sharpness }
        let lo = sharp.min() ?? 0, hi = sharp.max() ?? 0
        return group.members.map { id in
            guard let s = signals[id] else {
                return Scored(id: id, total: 0, aesthetics: 0, sharpness: 0, faceQuality: 0)
            }
            let sharpN = hi > lo ? (s.sharpness - lo) / (hi - lo) : 1
            let face = s.faceQuality ?? 0.5
            let total = weights.aesthetics * s.aesthetics
                + weights.sharpness * sharpN
                + weights.faceQuality * face
                - (s.isUtility ? weights.utilityPenalty : 0)
            return Scored(id: id, total: total, aesthetics: s.aesthetics, sharpness: sharpN, faceQuality: face)
        }
    }

    /// The recommended keep set: the single best asset plus every favourite.
    public func recommendedKeeps(_ group: SimilarityGroup,
                                 info: [AssetID: AssetInfo],
                                 signals: [AssetID: QualitySignals]) -> Set<AssetID> {
        let scored = score(group, signals: signals)
        let best = scored.max { lhs, rhs in
            if lhs.total != rhs.total { return lhs.total < rhs.total }
            return tieBreak(info[lhs.id], info[rhs.id])
        }
        var keeps = Set(group.members.filter { info[$0]?.isFavorite == true })
        if let best { keeps.insert(best.id) }
        return keeps
    }

    /// true when `lhs` should rank below `rhs`.
    /// Order: favourite > edited > resolution > file size > earlier capture.
    private func tieBreak(_ lhs: AssetInfo?, _ rhs: AssetInfo?) -> Bool {
        guard let l = lhs, let r = rhs else { return lhs == nil && rhs != nil }
        if l.isFavorite != r.isFavorite { return !l.isFavorite }
        if l.hasEdits != r.hasEdits { return !l.hasEdits }
        if l.pixelCount != r.pixelCount { return l.pixelCount < r.pixelCount }
        if l.fileSize != r.fileSize { return l.fileSize < r.fileSize }
        return l.creationDate > r.creationDate
    }
}
