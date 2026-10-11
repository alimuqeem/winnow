import AVFoundation
import Foundation
import Observation
import WinnowCore

/// Compress Videos tool state (PLAN.md Phase 6).
@MainActor
@Observable
final class VideoModel {
    enum Status: Equatable {
        case ready
        case downloading(Double)
        case compressing(Double)
        case compressed(url: URL, size: Int64, seconds: Double)
        case failed(String)
        case replaced(saved: Int64)
    }

    struct Item: Identifiable, Equatable {
        let record: PhotoLibraryService.VideoRecord
        var plan: VideoPlan
        var status: Status = .ready
        var id: AssetID { record.id }
        static func == (a: Item, b: Item) -> Bool { a.id == b.id && a.plan == b.plan && a.status == b.status }

        var compressedURL: URL? { if case let .compressed(url, _, _) = status { url } else { nil } }
        var compressedSize: Int64? { if case let .compressed(_, size, _) = status { size } else { nil } }
    }

    private(set) var loading = false
    private(set) var loaded = false
    private(set) var items: [Item] = []
    private(set) var skippedCount = 0
    private(set) var running = false
    private(set) var savedThisSession: Int64 = 0
    var selection = Set<AssetID>()
    var quality: VideoQuality = .medium { didSet { replan() } }
    var lastError: String?

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var records: [PhotoLibraryService.VideoRecord] = []
    @ObservationIgnored private var task: Task<Void, Never>?

    init(app: AppModel) { self.app = app }

    var candidates: [Item] { items.filter { $0.plan.estimatedSize != nil } }
    var compressed: [Item] { items.filter { $0.compressedURL != nil } }

    var estimatedSaving: Int64 {
        candidates.reduce(0) { $0 + max(0, $1.record.facts.fileSize - ($1.plan.estimatedSize ?? $1.record.facts.fileSize)) }
    }

    var compressedSaving: Int64 {
        compressed.reduce(0) { $0 + max(0, $1.record.facts.fileSize - ($1.compressedSize ?? 0)) }
    }

    /// Shows the cached list instantly (reading 8k videos from Photos takes ~20 s),
    /// then refreshes from Photos in the background.
    func load() async {
        guard !loading else { return }
        loading = true
        if let cached = await Task.detached(operation: { Self.readCache() }).value {
            records = cached
            loaded = true
            replan()
        }
        let fresh = await Task.detached(priority: .userInitiated) { PhotoLibraryService.fetchVideos() }.value
        records = fresh
        loading = false
        loaded = true
        replan()
        Task.detached(priority: .utility) { Self.writeCache(fresh) }
    }

    private nonisolated static var cacheURL: URL {
        AnalysisCache.defaultURL.deletingLastPathComponent().appendingPathComponent("videos.json")
    }

    nonisolated static func readCache() -> [PhotoLibraryService.VideoRecord]? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode([PhotoLibraryService.VideoRecord].self, from: data)
    }

    private nonisolated static func writeCache(_ records: [PhotoLibraryService.VideoRecord]) {
        if let data = try? JSONEncoder().encode(records) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// Re-plan for the current quality; keeps results of videos already compressed.
    private func replan() {
        let previous = Dictionary(items.map { ($0.id, $0.status) }, uniquingKeysWith: { a, _ in a })
        var next: [Item] = []
        var skipped = 0
        for record in records {
            let plan = VideoPlan.make(record.facts, quality: quality)
            if plan.skipReason != nil, previous[record.id] == nil { skipped += 1; continue }
            var item = Item(record: record, plan: plan)
            if let status = previous[record.id], status != .ready { item.status = status }
            next.append(item)
        }
        items = next.sorted { $0.record.facts.fileSize > $1.record.facts.fileSize }
        skippedCount = skipped
        selection = selection.filter { id in items.contains { $0.id == id } }
    }

    // MARK: - Compress

    func compressSelected() {
        let ids = items.filter { selection.contains($0.id) && $0.plan.estimatedSize != nil && $0.compressedURL == nil }.map(\.id)
        guard !ids.isEmpty, !running else { return }
        running = true
        lastError = nil
        let quality = quality
        task = Task {
            let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                                 reason: "Compressing videos")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            for id in ids {
                if Task.isCancelled { break }
                await compress(id, quality: quality)
            }
            running = false
        }
    }

    func cancel() { task?.cancel() }

    private func compress(_ id: AssetID, quality: VideoQuality) async {
        set(id, .downloading(0))
        guard let asset = await PhotoLibraryService.avAsset(for: id, progress: { [weak self] p in
            Task { @MainActor in self?.set(id, .downloading(p)) }
        }) else {
            set(id, .failed("Couldn't load the original from Photos"))
            return
        }
        set(id, .compressing(0))
        do {
            let originalSize = items.first { $0.id == id }?.record.facts.fileSize
            let result = try await VideoCompressor.compress(asset, quality: quality, originalSize: originalSize) { [weak self] p in
                Task { @MainActor in
                    guard let self, case .compressing = self.status(of: id) else { return }
                    self.set(id, .compressing(p))
                }
            }
            let original = items.first { $0.id == id }?.record.facts.fileSize ?? 0
            if Double(result.size) > Double(original) * (1 - VideoPlan.minimumSaving) {
                try? FileManager.default.removeItem(at: result.url)
                set(id, .failed("Already efficient (would save only \(percent(1 - Double(result.size) / Double(max(original, 1)))))"))
            } else {
                set(id, .compressed(url: result.url, size: result.size, seconds: result.seconds))
            }
        } catch {
            set(id, .failed(error.localizedDescription))
        }
    }

    // MARK: - Replace

    /// One atomic Photos change for every compressed video (one system prompt).
    func replaceCompressed(_ ids: Set<AssetID>? = nil) async {
        guard let app else { return }
        let ready = compressed.filter { ids?.contains($0.id) ?? true }
        let jobs = ready.compactMap { item in item.compressedURL.map { (original: item.id, file: $0) } }
        guard !jobs.isEmpty else { return }
        do {
            try await app.library.replaceVideos(jobs)
            for item in ready {
                let saved = item.record.facts.fileSize - (item.compressedSize ?? 0)
                savedThisSession += saved
                if let url = item.compressedURL { try? FileManager.default.removeItem(at: url) }
                set(item.id, .replaced(saved: saved))
            }
            selection.subtract(ready.map(\.id))
            lastError = nil
        } catch {
            lastError = "Nothing was replaced: \(error.localizedDescription)"
        }
    }

    /// Throw away a compressed copy (keeps the original).
    func discard(_ id: AssetID) {
        guard let item = items.first(where: { $0.id == id }), let url = item.compressedURL else { return }
        try? FileManager.default.removeItem(at: url)
        set(id, .ready)
    }

    // MARK: - Helpers

    func status(of id: AssetID) -> Status? { items.first { $0.id == id }?.status }

    private func set(_ id: AssetID, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    /// Leftover compressed files from earlier runs are never reused; clear them on launch.
    nonisolated static func clearLeftovers() {
        let dir = VideoCompressor.outputDirectory
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
