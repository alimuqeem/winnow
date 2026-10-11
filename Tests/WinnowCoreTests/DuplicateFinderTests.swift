import XCTest
@testable import WinnowCore

final class DuplicateFinderTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_600_000_000)

    /// Random unit vector, plus a copy nudged by `noise`.
    private func unit(_ rng: inout SplitMix64, dim: Int = 64) -> [Float] {
        let v = (0..<dim).map { _ in Float(rng.nextGaussian()) }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    private func nudged(_ v: [Float], _ noise: Float, _ rng: inout SplitMix64) -> [Float] {
        let w = v.map { $0 + noise * Float(rng.nextGaussian()) }
        let n = sqrt(w.reduce(0) { $0 + $1 * $1 })
        return w.map { $0 / n }
    }

    func testFindsCopiesYearsApartAndIgnoresDistinctPhotos() {
        var rng = SplitMix64(seed: 42)
        var assets: [AssetInfo] = []
        var vectors: [AssetID: FeatureVector] = [:]
        // 300 distinct photos…
        for i in 0..<300 {
            let id = AssetID("p\(i)")
            assets.append(AssetInfo(id: id, creationDate: t0 + Double(i) * 86_400))
            vectors[id] = FeatureVector(unit(&rng))
        }
        // …plus a re-import of p7 five years later (tiny encoding noise) and an exact copy of p200.
        let copyA = AssetID("p7-copy"), copyB = AssetID("p200-copy")
        assets.append(AssetInfo(id: copyA, creationDate: t0 + 5 * 365 * 86_400))
        vectors[copyA] = FeatureVector(nudged(vectors[AssetID("p7")]!.values, 0.004, &rng))
        assets.append(AssetInfo(id: copyB, creationDate: t0 + 400 * 86_400))
        vectors[copyB] = vectors[AssetID("p200")]

        let groups = DuplicateFinder.photoGroups(assets, vectors: vectors)
        XCTAssertEqual(Set(groups.map { Set($0.members) }),
                       [[AssetID("p7"), copyA], [AssetID("p200"), copyB]])
    }

    func testBurstChainIsNotOneDuplicateGroup() {
        // Frames of a burst: each step is a small drift, so neighbours are within
        // the threshold but the ends of the chain are not.
        var rng = SplitMix64(seed: 7)
        var v = unit(&rng)
        var assets: [AssetInfo] = []
        var vectors: [AssetID: FeatureVector] = [:]
        for i in 0..<8 {
            let id = AssetID("f\(i)")
            assets.append(AssetInfo(id: id, creationDate: t0 + Double(i) * 0.1))
            vectors[id] = FeatureVector(v)
            v = nudged(v, 0.06, &rng)
        }
        let first = vectors[AssetID("f0")]!, last = vectors[AssetID("f7")]!
        XCTAssertGreaterThan(first.distance(to: last), DuplicateFinder.photoThreshold)   // premise
        for group in DuplicateFinder.photoGroups(assets, vectors: vectors) {
            for a in group.members { for b in group.members {
                XCTAssertLessThanOrEqual(vectors[a]!.distance(to: vectors[b]!), DuplicateFinder.photoThreshold)
            } }
        }
    }

    func testVideoDuplicatesNeedShapeDurationAndTimeOrSize() {
        let a = DuplicateFinder.VideoKey(id: AssetID("a"), width: 2160, height: 3840, duration: 2068.0, creationDate: t0, fileSize: 7_000_000_000)
        let b = DuplicateFinder.VideoKey(id: AssetID("b"), width: 2160, height: 3840, duration: 2068.02, creationDate: t0, fileSize: 6_999_000_000)
        let differentClip = DuplicateFinder.VideoKey(id: AssetID("c"), width: 2160, height: 3840, duration: 2068.01,
                                                     creationDate: t0 + 3600, fileSize: 5_000_000_000)
        let groups = DuplicateFinder.videoGroups([a, b, differentClip])
        XCTAssertEqual(groups.map { Set($0.members) }, [[AssetID("a"), AssetID("b")]])
    }

    func testKeepsFavouriteThenHighestResolution() {
        let small = AssetInfo(id: AssetID("s"), creationDate: t0, pixelWidth: 1280, pixelHeight: 960)
        let big = AssetInfo(id: AssetID("b"), creationDate: t0 + 99, pixelWidth: 4032, pixelHeight: 3024)
        let fav = AssetInfo(id: AssetID("f"), creationDate: t0, pixelWidth: 640, pixelHeight: 480, isFavorite: true)
        let info = [small.id: small, big.id: big, fav.id: fav]
        XCTAssertEqual(DuplicateFinder.recommendedKeeps(SimilarityGroup(members: [small.id, big.id]), info: info), [big.id])
        XCTAssertEqual(DuplicateFinder.recommendedKeeps(SimilarityGroup(members: [small.id, big.id, fav.id]), info: info), [fav.id])
    }
}
