import CoreGraphics
import Foundation
import Vision
import WinnowCore

/// Per-asset analysis, run once and cached (PLAN.md Phase 2).
///
/// One pass per asset on a 256 px derivative:
/// - feature print   — GenerateImageFeaturePrintRequest (distance → SimilarityGraph)
/// - aesthetics      — CalculateImageAestheticsScoresRequest (overallScore, isUtility)
/// - face quality    — DetectFaceCaptureQualityRequest (mean over faces)
/// - sharpness       — variance of the Laplacian on a grayscale copy
enum AnalysisService {
    /// Every photo is analysed at exactly this size. Feature prints of the same
    /// photo at 256 vs 512 px differ by ~0.4 (more than the Similar tolerance),
    /// so sizes must never be mixed. 256 px derivatives are local for the whole
    /// library even with iCloud "Optimise Mac Storage" (512 px needed a ~1 s
    /// download for ~35% of photos). Bump `version` whenever this changes.
    static let imageSide: CGFloat = 256
    static let version = "2-256px"

    struct Result: Sendable {
        var vector: FeatureVector
        var signals: QualitySignals
    }

    static func analyse(_ image: CGImage) async throws -> Result {
        async let print = GenerateImageFeaturePrintRequest().perform(on: image)
        async let aesthetics = CalculateImageAestheticsScoresRequest().perform(on: image)
        async let faces = DetectFaceCaptureQualityRequest().perform(on: image)

        let fp = try await print
        let vector = fp.data.withUnsafeBytes { FeatureVector(Array($0.bindMemory(to: Float.self))) }
        let ae = try await aesthetics
        let faceScores = (try? await faces)?.compactMap { $0.captureQuality?.score } ?? []

        return Result(vector: vector,
                      signals: QualitySignals(aesthetics: (Double(ae.overallScore) + 1) / 2,
                                              sharpness: sharpness(of: image),
                                              faceQuality: faceScores.isEmpty ? nil
                                                  : Double(faceScores.reduce(0, +)) / Double(faceScores.count),
                                              isUtility: ae.isUtility))
    }

    /// Variance of the 4-neighbour Laplacian on an 8-bit grayscale copy (≤ 512 px).
    /// At 256 px this catches motion blur and missed focus, not fine detail.
    /// Higher = sharper. Only meaningful relative to other photos of the same scene,
    /// so the Recommender normalises it within each group.
    static func sharpness(of image: CGImage) -> Double {
        let scale = min(1, 512 / Double(max(image.width, image.height)))
        let w = max(3, Int(Double(image.width) * scale)), h = max(3, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        var sum = 0.0, sumSq = 0.0
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                let lap = 4 * Double(pixels[i]) - Double(pixels[i - 1]) - Double(pixels[i + 1])
                    - Double(pixels[i - w]) - Double(pixels[i + w])
                sum += lap
                sumSq += lap * lap
            }
        }
        let n = Double((w - 2) * (h - 2))
        let mean = sum / n
        return sumSq / n - mean * mean
    }
}
