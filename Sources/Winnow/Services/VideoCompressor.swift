import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox
import WinnowCore

/// HEVC re-encode at constant quality (PLAN.md Phase 6).
///
/// AVAssetReader → AVAssetWriter rather than an export preset, so quality is
/// controllable per tier. The encode stops early once the projected size shows
/// the saving would be under `VideoPlan.minimumSaving`. Audio is passed through untouched; rotation,
/// the file's metadata (creation date, location) and HDR (10-bit, HLG/PQ colour)
/// are carried over. Dolby Vision RPU metadata is not (the HLG base layer is).
enum VideoCompressor {
    struct Result: Sendable {
        var url: URL
        var size: Int64
        var seconds: Double
        var sourceBitrate: Int
        var frameRate: Double
        var isHDR: Bool
        var transferFunction: String?
    }

    enum Failure: LocalizedError {
        case noVideoTrack, cannotRead(String), cannotWrite(String), cancelled, notWorthIt(projectedSaving: Double)
        var errorDescription: String? {
            switch self {
            case let .notWorthIt(saving): "Already efficient (would save only \(Int((max(0, saving) * 100).rounded()))%)"
            case .noVideoTrack: "No video track"
            case let .cannotRead(m): "Couldn't read the video: \(m)"
            case let .cannotWrite(m): "Couldn't write the compressed video: \(m)"
            case .cancelled: "Cancelled"
            }
        }
    }

    static var outputDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Winnow/compressed", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Compresses `asset` into a new .mov in `outputDirectory`. `progress` gets 0...1.
    /// - Parameter originalSize: if given, the encode aborts with `.notWorthIt` when the
    ///   projected output would save less than `VideoPlan.minimumSaving`.
    static func compress(_ asset: AVAsset, quality: VideoQuality, constantQuality: Float? = nil,
                         originalSize: Int64? = nil,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        let started = Date()
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideoTrack }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let (naturalSize, transform, fps, estimatedRate, formats) =
            try await video.load(.naturalSize, .preferredTransform, .nominalFrameRate, .estimatedDataRate, .formatDescriptions)
        let duration = try await asset.load(.duration).seconds
        let metadata = try await asset.load(.metadata)

        let color = colorProperties(formats.first)
        let width = Int(naturalSize.width.rounded()), height = Int(naturalSize.height.rounded())

        let url = outputDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        let reader: AVAssetReader, writer: AVAssetWriter
        do {
            reader = try AVAssetReader(asset: asset)
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        } catch {
            throw Failure.cannotRead(error.localizedDescription)
        }
        // Keep the file's capture date even when it lives only in the movie header.
        var items = metadata
        let hasDate = items.contains { $0.identifier == .quickTimeMetadataCreationDate || $0.commonKey == .commonKeyCreationDate }
        if !hasDate, let date = try? await asset.load(.creationDate), let value = try? await date.load(.dateValue) {
            let item = AVMutableMetadataItem()
            item.identifier = .quickTimeMetadataCreationDate
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            item.value = ISO8601DateFormatter().string(from: value) as NSString
            items.append(item)
        }
        writer.metadata = items
        writer.shouldOptimizeForNetworkUse = false

        // Video: decode to 8- or 10-bit YUV, encode HEVC Main / Main10.
        let pixelFormat = color.isHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let videoOut = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat])
        videoOut.alwaysCopiesSampleData = false
        var videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProperties(constantQuality: constantQuality ?? quality.constantQuality,
                                                                  fps: fps, hdr: color.isHDR),
        ]
        if let props = color.writerProperties { videoSettings[AVVideoColorPropertiesKey] = props }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoIn.transform = transform
        videoIn.expectsMediaDataInRealTime = false

        // Audio: passthrough, every track (iPhones add a spatial-audio track).
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for audio in audioTracks {
            let out = AVAssetReaderTrackOutput(track: audio, outputSettings: nil)
            let hint = try await audio.load(.formatDescriptions).first
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if let language = try? await audio.load(.languageCode) { input.languageCode = language }
            if reader.canAdd(out), writer.canAdd(input) {
                reader.add(out); writer.add(input)
                audioPairs.append((out, input))
            }
        }
        guard reader.canAdd(videoOut), writer.canAdd(videoIn) else { throw Failure.cannotWrite("unsupported settings") }
        reader.add(videoOut)
        writer.add(videoIn)

        guard reader.startReading() else { throw Failure.cannotRead(reader.error?.localizedDescription ?? "unknown") }
        guard writer.startWriting() else { throw Failure.cannotWrite(writer.error?.localizedDescription ?? "unknown") }
        writer.startSession(atSourceTime: .zero)

        let box = CancelBox(reader: reader, writer: writer)
        let guardrail = SizeGuard(url: url, limit: originalSize.map { Double($0) * (1 - VideoPlan.minimumSaving) }, box: box)
        do {
            try await withTaskCancellationHandler {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        await pump(videoOut, into: videoIn, label: "video", box: box) { time in
                            guard duration > 0 else { return }
                            let p = min(1, time / duration)
                            progress(p)
                            guardrail.check(progress: p)
                        }
                    }
                    for (i, (out, input)) in audioPairs.enumerated() {
                        group.addTask { await pump(out, into: input, label: "audio\(i)", box: box) { _ in } }
                    }
                    try await group.waitForAll()
                }
            } onCancel: {
                box.cancel()
            }
        }
        if let projected = guardrail.abortedAt {
            try? FileManager.default.removeItem(at: url)
            throw Failure.notWorthIt(projectedSaving: 1 - projected / Double(originalSize ?? 1))
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: url)
            throw Failure.cancelled
        }
        if reader.status == .failed {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw Failure.cannotRead(reader.error?.localizedDescription ?? "unknown")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            try? FileManager.default.removeItem(at: url)
            throw Failure.cannotWrite(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        progress(1)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        return Result(url: url, size: size, seconds: Date().timeIntervalSince(started),
                      sourceBitrate: Int(estimatedRate), frameRate: Double(fps), isHDR: color.isHDR,
                      transferFunction: color.transfer)
    }

    private static func compressionProperties(constantQuality: Float, fps: Float, hdr: Bool) -> [String: Any] {
        [
            AVVideoQualityKey: constantQuality,
            AVVideoExpectedSourceFrameRateKey: max(1, Int(fps.rounded())),
            AVVideoProfileLevelKey: hdr ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel,
            AVVideoAllowFrameReorderingKey: true,
        ]
    }

    /// Copies samples until the reader runs dry, or until `box` is cancelled
    /// (a cancelled writer stops asking for data, so the pump must be released).
    private static func pump(_ output: AVAssetReaderTrackOutput, into input: AVAssetWriterInput, label: String,
                             box: CancelBox, progress: @escaping (Double) -> Void) async {
        let queue = DispatchQueue(label: "winnow.compress.\(label)")
        // Only touched on `queue`, serially.
        nonisolated(unsafe) let input = input, output = output
        let latch = Latch()
        box.register(latch)
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            latch.arm(done)
            input.requestMediaDataWhenReady(on: queue) {
                while !latch.isOpen, input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer() else {
                        input.markAsFinished()
                        latch.open()
                        return
                    }
                    progress(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
                    if !input.append(sample) {
                        // The writer failed: release every pump, not just this one.
                        box.cancel()
                        return
                    }
                }
            }
        }
    }

    /// Resumes a continuation exactly once, from whichever side gets there first.
    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        var isOpen: Bool { lock.withLock { opened } }

        func arm(_ c: CheckedContinuation<Void, Never>) {
            let resumeNow = lock.withLock { () -> Bool in
                if opened { return true }
                continuation = c
                return false
            }
            if resumeNow { c.resume() }
        }

        func open() {
            let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                guard !opened else { return nil }
                opened = true
                defer { continuation = nil }
                return continuation
            }
            c?.resume()
        }
    }

    /// Projects the final size from bytes written so far; cancels once it clearly
    /// exceeds the limit. Only called from the video pump's serial queue.
    private final class SizeGuard: @unchecked Sendable {
        let url: URL, limit: Double?, box: CancelBox
        private var nextCheck = 0.10
        private(set) var abortedAt: Double?

        init(url: URL, limit: Double?, box: CancelBox) { self.url = url; self.limit = limit; self.box = box }

        func check(progress: Double) {
            guard let limit, abortedAt == nil, progress >= nextCheck, progress < 0.97 else { return }
            nextCheck = progress + 0.05
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.doubleValue ?? 0
            let projected = written / progress
            // 15% slack: early-written bytes over-represent keyframes.
            if projected > limit * 1.15 {
                abortedAt = projected
                box.cancel()
            }
        }
    }

    private final class CancelBox: @unchecked Sendable {
        let reader: AVAssetReader, writer: AVAssetWriter
        private let lock = NSLock()
        private var latches: [Latch] = []
        private var cancelled = false

        init(reader: AVAssetReader, writer: AVAssetWriter) { self.reader = reader; self.writer = writer }

        func register(_ latch: Latch) {
            let already = lock.withLock { () -> Bool in
                latches.append(latch)
                return cancelled
            }
            if already { latch.open() }
        }

        func cancel() {
            let toOpen = lock.withLock { () -> [Latch] in
                guard !cancelled else { return [] }
                cancelled = true
                return latches
            }
            reader.cancelReading()
            writer.cancelWriting()
            toOpen.forEach { $0.open() }
        }
    }

    // MARK: - Colour

    private struct Color {
        var isHDR = false
        var transfer: String?
        var writerProperties: [String: Any]?
    }

    /// The transfer function of a file's first video track (for checks).
    static func transferFunction(of asset: AVAsset) async -> String? {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let format = try? await track.load(.formatDescriptions).first else { return nil }
        return colorProperties(format).transfer
    }

    private static func colorProperties(_ format: CMFormatDescription?) -> Color {
        guard let format else { return Color() }
        let ext = CMFormatDescriptionGetExtensions(format) as? [String: Any] ?? [:]
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String
        let primaries = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String
        let matrix = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String
        let hdrTransfers = [kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String,
                            kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String]
        var color = Color(isHDR: transfer.map(hdrTransfers.contains) ?? false, transfer: transfer)
        if let transfer, let primaries, let matrix {
            color.writerProperties = [AVVideoTransferFunctionKey: transfer,
                                      AVVideoColorPrimariesKey: primaries,
                                      AVVideoYCbCrMatrixKey: matrix]
        }
        return color
    }
}
