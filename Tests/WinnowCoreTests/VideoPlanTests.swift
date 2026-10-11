import XCTest
@testable import WinnowCore

final class VideoPlanTests: XCTestCase {
    /// A typical older phone clip: 1080p, 60 s, 150 MB (≈20 Mbps H.264).
    private let phoneClip = VideoFacts(width: 1920, height: 1080, duration: 60, fileSize: 150_000_000)

    func testTypicalPhoneClipShrinksByAtLeast70Percent() throws {
        let plan = VideoPlan.make(phoneClip, quality: .medium)
        let size = try XCTUnwrap(plan.estimatedSize)
        XCTAssertLessThan(Double(size) / Double(phoneClip.fileSize), 0.30)
    }

    func testHigherQualityMeansBiggerFile() throws {
        let low = try XCTUnwrap(VideoPlan.make(phoneClip, quality: .low).estimatedSize)
        let high = try XCTUnwrap(VideoPlan.make(phoneClip, quality: .high).estimatedSize)
        XCTAssertLessThan(low, high)
    }

    func testAlreadyEfficientVideoIsSkipped() {
        var v = phoneClip
        v.fileSize = 16_000_000                          // ≈2.4 Mbps already
        XCTAssertEqual(VideoPlan.make(v, quality: .medium).skipReason, "Already efficient")
    }

    func testSpecialVideosAreSkipped() {
        var v = phoneClip
        v.isSlowMo = true
        XCTAssertEqual(VideoPlan.make(v, quality: .medium).skipReason, "Slo-mo")
        v = phoneClip
        v.isEdited = true
        XCTAssertEqual(VideoPlan.make(v, quality: .medium).skipReason, "Edited in Photos")
    }

    func testBitrateFloorForTinyVideos() {
        XCTAssertEqual(VideoPlan.targetBitrate(width: 320, height: 240, frameRate: 15, quality: .low),
                       VideoPlan.minimumVideoBitrate)
    }

    func testVeryShortClipsAreSkipped() {
        var v = phoneClip
        v.duration = 1.4
        XCTAssertEqual(VideoPlan.make(v, quality: .medium).skipReason, "Too short")
    }
}
