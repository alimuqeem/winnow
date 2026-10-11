// Minimal assertions for scripts/check-core.sh (no XCTest without Xcode).
import Foundation
import WinnowCore

let t0 = Date(timeIntervalSince1970: 1_700_000_000)
func asset(_ id: String, _ s: TimeInterval) -> AssetInfo { AssetInfo(id: AssetID(id), creationDate: t0 + s) }
func check(_ ok: Bool, _ what: String) { if !ok { print("✗ \(what)"); exit(1) } }

let d: [Set<String>: Float] = [["a", "b"]: 0.1, ["b", "c"]: 0.3, ["c", "d"]: 0.1]
let g = SimilarityGraph(assets: [asset("a", 0), asset("b", 100), asset("c", 200), asset("d", 300)],
                        timeWindow: 600, maxThreshold: 1) { d[[$0.rawValue, $1.rawValue]] }
check(g.groups(threshold: 0.2).map(\.members.count) == [2, 2], "tight threshold splits")
check(g.groups(threshold: 0.5).map(\.members.count) == [4], "loose threshold merges")
check(g.groups(threshold: 0.5, maxSpan: 150).map(\.members.count) == [2, 2], "maxSpan refuses weakest link")

let grp = SimilarityGroup(members: [AssetID("a"), AssetID("b")])
var s = ReviewSession(groups: [grp], recommended: [grp.id: [AssetID("a")]], favorites: [])
s.keepAll(); s.undo()
check(s.keeps[grp.id] == [AssetID("a")], "undo restores")
s.confirmCurrent()
check(s.pendingDeletions == [AssetID("b")], "confirmed group yields deletion")

print("✓ smoke tests pass")
