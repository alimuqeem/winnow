import Foundation

/// Which videos are worth re-encoding, at what bitrate, and the expected saving
/// (PLAN.md Phase 6). Pure logic so it can be unit-tested.
public enum VideoQuality: String, CaseIterable, Sendable, Identifiable, Codable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    public var id: String { rawValue }

    /// VideoToolbox constant-quality setting (0–1) used for the actual encode.
    /// Measured 2026-10-11 on real iPhone clips (PSNR vs original): 0.5 → 34–40 dB,
    /// 0.6 → 37–44 dB. Bitrate targets were rejected: the same 0.05 bpp gave 39 dB
    /// on one 4K clip and 27 dB on another.
    public var constantQuality: Float {
        switch self {
        case .low: 0.45
        case .medium: 0.55
        case .high: 0.65
        }
    }

    /// Typical HEVC bits per pixel per frame at this quality — only for the
    /// "~estimated size" shown before encoding. Real sizes depend on content;
    /// measured Medium outputs were 0.057–0.084 bpp, so this leans conservative.
    public var bitsPerPixel: Double {
        switch self {
        case .low: 0.050
        case .medium: 0.075
        case .high: 0.110
        }
    }
}

public struct VideoFacts: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public var duration: TimeInterval
    public var fileSize: Int64
    /// Nominal frame rate if known (PhotoKit doesn't expose it; assume 30 until the file is read).
    public var frameRate: Double
    public var isSlowMo: Bool
    public var isTimeLapse: Bool
    public var isCinematic: Bool
    public var isEdited: Bool

    public init(width: Int, height: Int, duration: TimeInterval, fileSize: Int64, frameRate: Double = 30,
                isSlowMo: Bool = false, isTimeLapse: Bool = false, isCinematic: Bool = false, isEdited: Bool = false) {
        self.width = width; self.height = height; self.duration = duration; self.fileSize = fileSize
        self.frameRate = frameRate; self.isSlowMo = isSlowMo; self.isTimeLapse = isTimeLapse
        self.isCinematic = isCinematic; self.isEdited = isEdited
    }
}

public enum VideoPlan: Sendable, Hashable {
    case compress(targetBitrate: Int, estimatedSize: Int64)
    case skip(String)

    /// Audio is passed through; budget for it in estimates.
    public static let audioBitrate = 192_000
    /// Don't bother below this saving (also the encoder's early-abort threshold).
    public static let minimumSaving = 0.40
    /// Never target less than this (tiny clips, very low resolutions).
    public static let minimumVideoBitrate = 400_000

    public static func make(_ v: VideoFacts, quality: VideoQuality) -> VideoPlan {
        if v.isSlowMo { return .skip("Slo-mo") }
        if v.isTimeLapse { return .skip("Time-lapse") }
        if v.isCinematic { return .skip("Cinematic") }
        if v.isEdited { return .skip("Edited in Photos") }
        // Under ~3 s the container/keyframe overhead dominates: little to gain, visible loss.
        guard v.duration >= 3, v.width > 0, v.height > 0, v.fileSize > 0 else { return .skip("Too short") }

        let target = targetBitrate(width: v.width, height: v.height, frameRate: v.frameRate, quality: quality)
        let estimated = Int64(Double(target + audioBitrate) * v.duration / 8)
        let saving = 1 - Double(estimated) / Double(v.fileSize)
        guard saving >= minimumSaving else { return .skip("Already efficient") }
        return .compress(targetBitrate: target, estimatedSize: estimated)
    }

    public static func targetBitrate(width: Int, height: Int, frameRate: Double, quality: VideoQuality) -> Int {
        let fps = min(max(frameRate, 24), 60)
        return max(minimumVideoBitrate, Int(Double(width * height) * fps * quality.bitsPerPixel))
    }

    public var estimatedSize: Int64? {
        if case let .compress(_, size) = self { return size }
        return nil
    }

    public var skipReason: String? {
        if case let .skip(reason) = self { return reason }
        return nil
    }
}
