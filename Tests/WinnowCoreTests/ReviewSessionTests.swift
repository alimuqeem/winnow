import XCTest
@testable import WinnowCore

final class ReviewSessionTests: XCTestCase {
    private let a = AssetID("a"), b = AssetID("b"), c = AssetID("c")
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    func testFavouritesAreAlwaysRecommendedKeeps() {
        let group = SimilarityGroup(members: [a, b])
        let info = [a: AssetInfo(id: a, creationDate: t0),
                    b: AssetInfo(id: b, creationDate: t0, isFavorite: true)]
        let signals = [a: QualitySignals(aesthetics: 0.9, sharpness: 10),
                       b: QualitySignals(aesthetics: 0.1, sharpness: 1)]
        XCTAssertEqual(Recommender().recommendedKeeps(group, info: info, signals: signals), [a, b])
    }

    func testOnlyConfirmedGroupsProducePendingDeletions() {
        let g1 = SimilarityGroup(members: [a, b]), g2 = SimilarityGroup(members: [c, AssetID("d")])
        var s = ReviewSession(groups: [g1, g2], recommended: [g1.id: [a], g2.id: [c]], favorites: [])
        XCTAssertTrue(s.pendingDeletions.isEmpty)
        s.confirmCurrent()
        XCTAssertEqual(s.pendingDeletions, [b])
        XCTAssertEqual(s.current, g2)
    }

    func testUndoRedoAndReset() {
        let g = SimilarityGroup(members: [a, b, c])
        var s = ReviewSession(groups: [g], recommended: [g.id: [a]], favorites: [])
        s.keepAll()
        s.focus(c)
        s.keepOnlySelection()
        XCTAssertFalse(s.isKept(a, in: g))
        s.undo()
        XCTAssertTrue(s.isKept(b, in: g))
        s.redo()
        XCTAssertEqual(s.keeps[g.id], [c])
        s.resetToRecommended()
        XCTAssertEqual(s.keeps[g.id], [a])
    }

    func testSpaceTogglesWholeSelectionAndFocusStartsOnRecommended() {
        let g = SimilarityGroup(members: [a, b, c])
        var s = ReviewSession(groups: [g], recommended: [g.id: [b]], favorites: [])
        XCTAssertEqual(s.focusedID, b)
        s.moveFocus(by: 1, extend: true)            // select b + c
        XCTAssertEqual(s.selection, [b, c])
        s.toggleKeepSelection()                     // c not kept -> both kept
        XCTAssertEqual(s.keeps[g.id], [b, c])
        s.toggleKeepSelection()                     // both kept -> both deleted
        XCTAssertEqual(s.keeps[g.id], [])
    }

    func testConfirmWrapsToFirstUnconfirmedGroup() {
        let g1 = SimilarityGroup(members: [a, b]), g2 = SimilarityGroup(members: [c, AssetID("d")])
        var s = ReviewSession(groups: [g1, g2], recommended: [g1.id: [a], g2.id: [c]], favorites: [b])
        s.nextGroup()
        s.confirmCurrent()
        XCTAssertEqual(s.current, g1)
        XCTAssertTrue(s.currentHasFavorite)
        s.confirmCurrent()
        XCTAssertTrue(s.isFinished)
    }

    func testPendingBinDedupesAndRestores() {
        var bin = PendingBin([a, b, a])
        XCTAssertEqual(bin.items, [a, b])
        bin.restore([a])
        XCTAssertEqual(bin.items, [b])
        XCTAssertFalse(bin.contains(a))
    }

    func testFeatureVectorDistanceIsSquaredEuclidean() {
        let x = FeatureVector([1, 0]), y = FeatureVector([0, 1])
        XCTAssertEqual(x.distance(to: y), 2, accuracy: 1e-6)          // |x-y|^2 = 2
        XCTAssertEqual(FeatureVector(data: x.data), x)
    }
}
