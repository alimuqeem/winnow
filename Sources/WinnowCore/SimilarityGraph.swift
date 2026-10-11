import Foundation

/// A sparse graph of "possibly similar" asset pairs, built once per scan.
///
/// Edges are computed only between assets whose capture times fall within
/// `timeWindow` of each other, and only kept when their distance is at or
/// below `maxThreshold` (the loosest tolerance the UI offers). Moving the
/// tolerance slider then just filters edges and reruns union-find, which is
/// fast enough to do live (see PLAN.md, design choice 1).
public struct SimilarityGraph: Sendable {
    public struct Edge: Hashable, Sendable {
        public let a: AssetID
        public let b: AssetID
        public let distance: Float
    }

    public let assets: [AssetInfo]          // sorted by creationDate
    public let edges: [Edge]                // sorted by distance ascending
    public let maxThreshold: Float

    /// - Parameters:
    ///   - distance: feature-print distance between two assets, or nil if
    ///     either has no print (e.g. analysis failed).
    public init(assets: [AssetInfo],
                timeWindow: TimeInterval,
                maxThreshold: Float,
                distance: (AssetID, AssetID) -> Float?) {
        let sorted = assets.sorted { $0.creationDate < $1.creationDate }
        var edges: [Edge] = []
        for i in sorted.indices {
            var j = i + 1
            while j < sorted.count,
                  sorted[j].creationDate.timeIntervalSince(sorted[i].creationDate) <= timeWindow {
                if let d = distance(sorted[i].id, sorted[j].id), d <= maxThreshold {
                    edges.append(Edge(a: sorted[i].id, b: sorted[j].id, distance: d))
                }
                j += 1
            }
        }
        self.assets = sorted
        self.edges = edges.sorted { $0.distance < $1.distance }
        self.maxThreshold = maxThreshold
    }

    /// Groups of two or more assets connected by edges with distance <= threshold.
    ///
    /// `maxSpan` guards against single-linkage chaining: an edge is refused if
    /// merging would make a group span more than `maxSpan` seconds. Because
    /// edges are processed tightest-first, the weakest links are the ones refused.
    public func groups(threshold: Float, maxSpan: TimeInterval = .infinity) -> [SimilarityGroup] {
        // Only assets with at least one edge in range can end up in a group.
        let active = edges.prefix { $0.distance <= threshold }
        var touched = Set<AssetID>()
        for edge in active { touched.insert(edge.a); touched.insert(edge.b) }
        let nodes = assets.filter { touched.contains($0.id) }
        var uf = UnionFind(nodes)
        let dates = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.creationDate) })

        for edge in active {
            uf.union(edge.a, edge.b) { lhs, rhs in
                let lo = min(lhs.earliest, rhs.earliest), hi = max(lhs.latest, rhs.latest)
                return hi.timeIntervalSince(lo) <= maxSpan
            }
        }

        var buckets: [AssetID: [AssetID]] = [:]
        for asset in nodes { buckets[uf.find(asset.id), default: []].append(asset.id) }
        return buckets.values
            .filter { $0.count > 1 }
            .map { members in SimilarityGroup(members: members.sorted { dates[$0]! < dates[$1]! }) }
            .sorted { dates[$0.members[0]]! < dates[$1.members[0]]! }
    }

    // MARK: - Union-find with per-root time span

    private struct UnionFind {
        struct Span { var earliest: Date; var latest: Date }
        private var parent: [AssetID: AssetID] = [:]
        private var span: [AssetID: Span] = [:]

        init(_ assets: [AssetInfo]) {
            for asset in assets {
                parent[asset.id] = asset.id
                span[asset.id] = Span(earliest: asset.creationDate, latest: asset.creationDate)
            }
        }

        mutating func find(_ x: AssetID) -> AssetID {
            var root = x
            while let p = parent[root], p != root { root = p }
            var node = x
            while node != root, let p = parent[node] { parent[node] = root; node = p }
            return root
        }

        mutating func union(_ a: AssetID, _ b: AssetID, allow: (Span, Span) -> Bool) {
            let ra = find(a), rb = find(b)
            guard ra != rb else { return }
            let sa = span[ra]!, sb = span[rb]!
            guard allow(sa, sb) else { return }
            parent[rb] = ra
            span[ra] = Span(earliest: min(sa.earliest, sb.earliest), latest: max(sa.latest, sb.latest))
        }
    }
}
