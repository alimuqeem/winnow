import Accelerate
import Foundation

/// Whole-library exact/near-exact duplicate detection, ignoring capture time
/// (PLAN.md Phase 7, item 4).
///
/// Photos: comparing all pairs of 100k feature prints is ~5·10⁹ dot products, so
/// candidates come from random-hyperplane LSH (several tables of sign bits);
/// only vectors sharing a bucket in some table are compared exactly.
/// Videos: matched on metadata (dimensions, duration, and same capture time or size).
public enum DuplicateFinder {
    /// Squared-distance cut-off for "the same photo" (identical pixels give 0.000).
    /// Calibrated 2026-10-11 on direct pairs from a 104k library: ≤ 0.008 were the
    /// same picture (re-imports, re-encodes, static repeats); 0.010+ were already
    /// different burst frames or an annotated copy (Markup), which must not be deleted.
    public static let photoThreshold: Float = 0.008

    // MARK: - Photos

    /// Groups of photos whose prints are within `threshold` of each other.
    /// Members are sorted by creation date; groups by their first member's date.
    public static func photoGroups(_ assets: [AssetInfo], vectors: [AssetID: FeatureVector],
                                   threshold: Float = photoThreshold,
                                   tables: Int = 8, bits: Int = 16, seed: UInt64 = 0x5EED) -> [SimilarityGroup] {
        let items = assets.compactMap { a in vectors[a.id].map { (a, $0) } }
        guard items.count > 1, let dim = items.first?.1.values.count, dim > 0 else { return [] }

        var rng = SplitMix64(seed: seed)
        var compared = Set<Int64>()
        var edges: [(Int, Int, Float)] = []

        for _ in 0..<tables {
            // `bits` random hyperplanes, flattened row-major (bits × dim).
            let planes = (0..<(bits * dim)).map { _ in Float(rng.nextGaussian()) }
            var buckets: [UInt32: [Int]] = [:]
            for (i, item) in items.enumerated() {
                var key: UInt32 = 0
                item.1.values.withUnsafeBufferPointer { v in
                    planes.withUnsafeBufferPointer { p in
                        for b in 0..<bits {
                            var dot: Float = 0
                            vDSP_dotpr(v.baseAddress!, 1, p.baseAddress! + b * dim, 1, &dot, vDSP_Length(dim))
                            if dot > 0 { key |= 1 << UInt32(b) }
                        }
                    }
                }
                buckets[key, default: []].append(i)
            }
            for members in buckets.values where members.count > 1 {
                for x in 0..<members.count {
                    for y in (x + 1)..<members.count {
                        let i = members[x], j = members[y]
                        let pairKey = Int64(min(i, j)) << 32 | Int64(max(i, j))
                        guard compared.insert(pairKey).inserted else { continue }
                        let d = items[i].1.distance(to: items[j].1)
                        if d <= threshold { edges.append((i, j, d)) }
                    }
                }
            }
        }

        // Complete linkage: merge two clusters only if EVERY cross pair is within
        // the threshold. Single linkage chained burst frames (A≈B≈C…) into one
        // "duplicate" group even though the first and last frames differ.
        var cluster = Array(items.indices)                 // item -> cluster id
        var members: [Int: [Int]] = [:]
        for i in items.indices { members[i] = [i] }
        func within(_ a: Int, _ b: Int) -> Bool {
            items[a].1.distance(to: items[b].1) <= threshold
        }
        for (i, j, _) in edges.sorted(by: { $0.2 < $1.2 }) {
            let ci = cluster[i], cj = cluster[j]
            guard ci != cj, let mi = members[ci], let mj = members[cj] else { continue }
            guard mi.allSatisfy({ a in mj.allSatisfy { b in within(a, b) } }) else { continue }
            for m in mj { cluster[m] = ci }
            members[ci] = mi + mj
            members[cj] = nil
        }

        return members.values.map { $0.map { items[$0].0 } }
            .filter { $0.count > 1 }
            .map { $0.sorted { $0.creationDate < $1.creationDate } }
            .sorted { $0[0].creationDate < $1[0].creationDate }
            .map { SimilarityGroup(members: $0.map(\.id)) }
    }

    // MARK: - Videos

    public struct VideoKey: Sendable, Hashable {
        public let id: AssetID
        public let width: Int
        public let height: Int
        public let duration: TimeInterval
        public let creationDate: Date
        public let fileSize: Int64

        public init(id: AssetID, width: Int, height: Int, duration: TimeInterval, creationDate: Date, fileSize: Int64) {
            self.id = id; self.width = width; self.height = height; self.duration = duration
            self.creationDate = creationDate; self.fileSize = fileSize
        }
    }

    /// Same dimensions, duration within 0.05 s, and either the same capture time
    /// (±2 s) or the same file size. Different clips rarely satisfy both.
    public static func videoGroups(_ videos: [VideoKey]) -> [SimilarityGroup] {
        let byShape = Dictionary(grouping: videos) { "\($0.width)x\($0.height)" }
        var out: [[VideoKey]] = []
        for (_, list) in byShape where list.count > 1 {
            let sorted = list.sorted { $0.duration < $1.duration }
            var used = Set<Int>()
            for i in sorted.indices where !used.contains(i) {
                var group = [sorted[i]]
                var j = i + 1
                while j < sorted.count, sorted[j].duration - sorted[i].duration <= 0.05 {
                    let a = sorted[i], b = sorted[j]
                    let sameTime = abs(a.creationDate.timeIntervalSince(b.creationDate)) <= 2
                    let sameSize = a.fileSize > 0 && a.fileSize == b.fileSize
                    if !used.contains(j), sameTime || sameSize {
                        group.append(b)
                        used.insert(j)
                    }
                    j += 1
                }
                if group.count > 1 { used.insert(i); out.append(group) }
            }
        }
        return out
            .map { $0.sorted { $0.creationDate < $1.creationDate } }
            .sorted { $0[0].creationDate < $1[0].creationDate }
            .map { SimilarityGroup(members: $0.map(\.id)) }
    }

    // MARK: - Which copy to keep

    /// For exact copies quality scores are noise; keep the "most original" copy:
    /// favourite > edited > highest resolution > largest file > oldest. Favourites are always kept.
    public static func recommendedKeeps(_ group: SimilarityGroup, info: [AssetID: AssetInfo]) -> Set<AssetID> {
        let best = group.members.max { l, r in
            guard let a = info[l], let b = info[r] else { return info[l] == nil }
            if a.isFavorite != b.isFavorite { return !a.isFavorite }
            if a.hasEdits != b.hasEdits { return !a.hasEdits }
            if a.pixelCount != b.pixelCount { return a.pixelCount < b.pixelCount }
            if a.fileSize != b.fileSize { return a.fileSize < b.fileSize }
            return a.creationDate > b.creationDate
        }
        var keeps = Set(group.members.filter { info[$0]?.isFavorite == true })
        if let best { keeps.insert(best) }
        return keeps
    }
}

/// Small deterministic RNG so LSH buckets are reproducible across runs.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func nextGaussian() -> Double {
        let u1 = max(Double(next() >> 11) / Double(1 << 53), .leastNonzeroMagnitude)
        let u2 = Double(next() >> 11) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}
