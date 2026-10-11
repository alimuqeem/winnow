import XCTest
@testable import WinnowCore

final class SimilarityGraphTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func asset(_ id: String, _ seconds: TimeInterval) -> AssetInfo {
        AssetInfo(id: AssetID(id), creationDate: t0.addingTimeInterval(seconds))
    }

    private func graph(_ assets: [AssetInfo], _ d: [Set<String>: Float],
                       window: TimeInterval = 600, max: Float = 1.0) -> SimilarityGraph {
        SimilarityGraph(assets: assets, timeWindow: window, maxThreshold: max) { a, b in
            d[[a.rawValue, b.rawValue]]
        }
    }

    func testTighterThresholdSplitsGroups() {
        let g = graph([asset("a", 0), asset("b", 1), asset("c", 2)],
                      [["a", "b"]: 0.1, ["b", "c"]: 0.5, ["a", "c"]: 0.6])
        XCTAssertEqual(g.groups(threshold: 0.2).map(\.members), [[AssetID("a"), AssetID("b")]])
        XCTAssertEqual(g.groups(threshold: 0.5).map(\.members.count), [3])
    }

    func testPairsOutsideTimeWindowAreNeverCompared() {
        let g = graph([asset("a", 0), asset("b", 10_000)], [["a", "b"]: 0.0])
        XCTAssertTrue(g.groups(threshold: 1).isEmpty)
    }

    func testMaxSpanStopsChaining() {
        // a-b-c-d each 100 s apart, all near-identical: one chain of 300 s.
        let g = graph([asset("a", 0), asset("b", 100), asset("c", 200), asset("d", 300)],
                      [["a", "b"]: 0.1, ["b", "c"]: 0.3, ["c", "d"]: 0.1])
        XCTAssertEqual(g.groups(threshold: 0.5).map(\.members.count), [4])
        // Capped at 150 s, the weakest link (b-c) is the one refused.
        XCTAssertEqual(g.groups(threshold: 0.5, maxSpan: 150).map(\.members.count), [2, 2])
    }
}
