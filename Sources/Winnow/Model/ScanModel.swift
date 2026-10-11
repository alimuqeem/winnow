import Foundation
import Observation
import Photos
import WinnowCore

/// Scan → group → review state for one collection (PLAN.md Phases 2–4).
@MainActor
@Observable
final class ScanModel {
    enum Phase: Equatable {
        case idle
        case fetching
        case analysing(done: Int, total: Int)
        case grouping
        case ready
        case failed(String)
    }

    struct Stats: Equatable {
        var photos = 0
        var cached = 0
        var analysed = 0
        var failed = 0
        var downloaded = 0
        var seconds: Double = 0
        var edges = 0
    }

    let collectionID: String
    let title: String
    private(set) var phase: Phase = .idle
    private(set) var stats = Stats()
    private(set) var startedAt: Date?
    /// Photos only in iCloud, being downloaded in the scan's second pass.
    private(set) var downloadingCount = 0

    private(set) var assets: [AssetID: AssetInfo] = [:]
    private(set) var signals: [AssetID: QualitySignals] = [:]
    private(set) var graph: SimilarityGraph?
    /// Duplicates mode: groups are fixed (no tolerance), photos + videos.
    private(set) var fixedGroups: [SimilarityGroup]?
    /// Groups remaining at each preset (multi-pass progress), refreshed in the background.
    private(set) var presetCounts: [Tolerance.Preset: Int] = [:]
    /// Photos already kept in an earlier pass, as of the last regroup.
    private(set) var priorReviewed: Set<AssetID> = []

    var tolerance: Float = Tolerance.Preset.similar.threshold
    private(set) var session = ReviewSession(groups: [], recommended: [:], favorites: [])
    private(set) var regroupMillis: Double = 0

    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var regroupTask: Task<Void, Never>?
    @ObservationIgnored private var favorites: Set<AssetID> = []
    @ObservationIgnored private var appliedDeletions: Set<AssetID> = []
    @ObservationIgnored private var appliedConfirmed: Set<String> = []
    @ObservationIgnored private var appliedReviewed: Set<AssetID> = []
    @ObservationIgnored private var countsTask: Task<Void, Never>?

    var isDuplicates: Bool { collectionID == AppModel.duplicatesID }

    init(collectionID: String, title: String, app: AppModel) {
        self.collectionID = collectionID
        self.title = title
        self.app = app
    }

    var isRunning: Bool {
        switch phase {
        case .fetching, .analysing, .grouping: true
        default: false
        }
    }

    var groups: [SimilarityGroup] { session.groups }

    var eta: TimeInterval? {
        guard case let .analysing(done, total) = phase, done > 20, let startedAt else { return nil }
        let rate = Date().timeIntervalSince(startedAt) / Double(done)
        return rate * Double(total - done)
    }

    // MARK: - Scan

    func start() {
        guard !isRunning, let app else { return }
        let cache = app.cache, id = isDuplicates ? PhotoLibraryService.allPhotosID : collectionID
        let duplicates = isDuplicates
        startedAt = Date()
        phase = .fetching
        task = Task {
            // Keep full speed when the window is in the background (no App Nap).
            let activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled], reason: "Scanning photos for similar shots")
            defer { ProcessInfo.processInfo.endActivity(activity) }
            let began = Date()
            let fetched = await Task.detached(priority: .userInitiated) { PhotoLibraryService.fetchPhotos(in: id) }.value
            var stats = Stats(photos: fetched.count)

            let wanted = Dictionary(fetched.map { ($0.info.id, $0.modified) }, uniquingKeysWith: { a, _ in a })
            var entries = await cache.entries(for: wanted)
            stats.cached = entries.count

            let missing = fetched.filter { entries[$0.info.id] == nil }
            phase = .analysing(done: 0, total: missing.count)
            Log.scan.notice("scan \(id): \(fetched.count) photos, \(entries.count) cached, \(missing.count) to analyse")

            // Pass 1: everything available on this Mac, at full width.
            // Pass 2: iCloud-only photos, downloaded at a gentler width so a few
            // slow downloads can't stall the whole scan.
            let items = missing.map { ($0.asset, $0.info.id, $0.modified) }
            let local = await Self.analyse(items, network: false, width: Self.localWidth, cache: cache) { done in
                self.phase = .analysing(done: done, total: missing.count)
            }
            let localDone = local.results.count
            downloadingCount = local.unavailable.count
            if downloadingCount > 0 { Log.scan.notice("scan \(id): \(self.downloadingCount) photos are iCloud-only; downloading") }
            let remote = await Self.analyse(local.unavailable, network: true, width: 4, cache: cache) { done in
                self.phase = .analysing(done: localDone + done, total: missing.count)
            }
            for (assetID, entry) in local.results + remote.results { entries[assetID] = entry }
            stats.analysed = local.results.count + remote.results.count
            stats.downloaded = remote.results.count
            downloadingCount = 0
            stats.failed = missing.count - stats.analysed
            guard !Task.isCancelled else { phase = .idle; return }

            phase = .grouping
            var infos = fetched.map(\.info)
            let vectors = entries.mapValues(\.vector)
            if duplicates {
                let found = await Self.findDuplicates(photos: infos, vectors: vectors)
                infos += found.videoInfos
                fixedGroups = found.groups
                stats.edges = found.groups.count
            } else {
                let graph = await Task.detached(priority: .userInitiated) {
                    SimilarityGraph(assets: infos.filter { vectors[$0.id] != nil },
                                    timeWindow: Tolerance.timeWindow, maxThreshold: Tolerance.maxThreshold) { a, b in
                        guard let va = vectors[a], let vb = vectors[b] else { return nil }
                        return va.distance(to: vb)
                    }
                }.value
                self.graph = graph
                stats.edges = graph.edges.count
            }

            assets = Dictionary(infos.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            signals = entries.mapValues(\.signals)
            favorites = Set(infos.lazy.filter(\.isFavorite).map(\.id))
            if duplicates, let groups = fixedGroups {
                let photoIDs = groups.flatMap(\.members).filter { assets[$0]?.kind == .photo }
                let sizes = await Task.detached(priority: .userInitiated) { Self.fileSizes(photoIDs) }.value
                for (id, size) in sizes { assets[id]?.fileSize = size }
            }
            stats.seconds = Date().timeIntervalSince(began)
            self.stats = stats
            regroup()
            phase = .ready
            Log.scan.notice("scan \(id) done in \(stats.seconds, format: .fixed(precision: 1)) s: analysed \(stats.analysed), failed \(stats.failed), edges \(stats.edges), groups \(self.groups.count)")
        }
    }

    func cancel() { task?.cancel() }

    /// Phase 7 item 4: photo copies via LSH over cached prints; video copies via
    /// metadata (cached video list when available). Members get real file sizes
    /// so groups can be ordered by reclaimable space.
    private nonisolated static func findDuplicates(photos: [AssetInfo], vectors: [AssetID: FeatureVector])
        async -> (groups: [SimilarityGroup], videoInfos: [AssetInfo]) {
        await Task.detached(priority: .userInitiated) {
            let photoGroups = DuplicateFinder.photoGroups(photos, vectors: vectors)
            let records = VideoModel.readCache() ?? PhotoLibraryService.fetchVideos()
            let keys = records.map {
                DuplicateFinder.VideoKey(id: $0.id, width: $0.facts.width, height: $0.facts.height,
                                         duration: $0.facts.duration, creationDate: $0.creationDate, fileSize: $0.facts.fileSize)
            }
            let videoGroups = DuplicateFinder.videoGroups(keys)
            let inVideoGroups = Set(videoGroups.flatMap(\.members))
            let videoInfos = records.filter { inVideoGroups.contains($0.id) }.map {
                AssetInfo(id: $0.id, kind: .video, creationDate: $0.creationDate, pixelWidth: $0.facts.width,
                          pixelHeight: $0.facts.height, fileSize: $0.facts.fileSize,
                          isFavorite: $0.isFavorite, hasEdits: $0.facts.isEdited)
            }
            Log.scan.notice("duplicates: \(photoGroups.count) photo groups, \(videoGroups.count) video groups")
            return (photoGroups + videoGroups, videoInfos)
        }.value
    }

    private nonisolated static func fileSizes(_ ids: [AssetID]) -> [AssetID: Int64] {
        let assets = PhotoLibraryService.assets(ids)
        var sizes = [Int64](repeating: 0, count: assets.count)
        sizes.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let out = buffer
            DispatchQueue.concurrentPerform(iterations: assets.count) { out[$0] = PhotoLibraryService.fileSize(of: assets[$0]) }
        }
        return Dictionary(zip(assets.map { AssetID($0.localIdentifier) }, sizes), uniquingKeysWith: { a, _ in a })
    }

    private nonisolated static let localWidth = max(4, ProcessInfo.processInfo.activeProcessorCount)

    /// Bounded-concurrency analysis; saves to the cache in batches so quitting mid-scan resumes.
    /// Returns the analysed entries plus the items whose image wasn't available
    /// (only possible with `network: false`: iCloud-only photos).
    private nonisolated static func analyse(_ items: [(PHAsset, AssetID, Date)], network: Bool, width: Int,
                                            cache: AnalysisCache, progress: @MainActor @escaping (Int) -> Void)
        async -> (results: [(AssetID, AnalysisCache.Entry)], unavailable: [(PHAsset, AssetID, Date)]) {
        guard !items.isEmpty else { return ([], []) }
        enum Outcome { case done(AssetID, AnalysisCache.Entry), unavailable(Int), failed }
        var results: [(AssetID, AnalysisCache.Entry)] = []
        var unavailable: [(PHAsset, AssetID, Date)] = []
        var batch: [(AssetID, AnalysisCache.Entry)] = []
        var done = 0, lastReport = Date.distantPast

        await withTaskGroup(of: Outcome.self) { group in
            var next = 0
            func enqueue() {
                guard next < items.count else { return }
                let index = next
                let (asset, id, modified) = items[index]
                next += 1
                group.addTask {
                    guard let image = await PhotoLibraryService.analysisImage(for: asset, side: AnalysisService.imageSide, network: network) else {
                        return network ? .failed : .unavailable(index)
                    }
                    guard let r = try? await AnalysisService.analyse(image) else { return .failed }
                    return .done(id, AnalysisCache.Entry(modified: modified, vector: r.vector, signals: r.signals))
                }
            }
            for _ in 0..<width { enqueue() }
            for await outcome in group {
                switch outcome {
                case let .done(id, entry):
                    done += 1
                    results.append((id, entry))
                    batch.append((id, entry))
                case let .unavailable(index):
                    unavailable.append(items[index])
                case .failed:
                    done += 1
                }
                if batch.count >= 200 {
                    await cache.save(batch)
                    batch.removeAll(keepingCapacity: true)
                }
                if Date().timeIntervalSince(lastReport) > 0.25 {
                    lastReport = Date()
                    await progress(done)
                }
                if Task.isCancelled { group.cancelAll(); break }
                enqueue()
            }
        }
        await cache.save(batch)
        await progress(done)
        return (results, unavailable)
    }

    // MARK: - Grouping (Phase 3)

    /// Recompute groups at the current tolerance, synchronously (scan end, self-test).
    /// Drops groups already confirmed (persisted) and members in the bin or deleted.
    func regroup() {
        guard let input = regroupInput() else { return }
        let t = Date()
        apply(Self.computeGroups(input))
        regroupMillis = Date().timeIntervalSince(t) * 1000
    }

    /// Slider path: debounced and computed off the main thread (≈0.1–0.5 s on 100k photos).
    func scheduleRegroup() {
        regroupTask?.cancel()
        guard let input = regroupInput() else { return }
        regroupTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let t = Date()
            let result = await Task.detached(priority: .userInitiated) { Self.computeGroups(input) }.value
            guard !Task.isCancelled else { return }
            apply(result)
            regroupMillis = Date().timeIntervalSince(t) * 1000
        }
    }

    private struct RegroupInput: Sendable {
        let graph: SimilarityGraph?
        let fixed: [SimilarityGroup]?
        let tolerance: Float
        let excluded: Set<AssetID>
        let confirmed: Set<String>
        let assets: [AssetID: AssetInfo]
        let signals: [AssetID: QualitySignals]
    }

    private func regroupInput(tolerance: Float? = nil) -> RegroupInput? {
        guard graph != nil || fixedGroups != nil, let app else { return nil }
        return RegroupInput(graph: graph, fixed: fixedGroups, tolerance: tolerance ?? self.tolerance,
                            excluded: Set(app.bin.items).union(app.removed),
                            confirmed: app.confirmedGroups, assets: assets, signals: signals)
    }

    /// Groups at the input's tolerance (or the fixed duplicate groups), minus
    /// confirmed groups and binned/deleted members. No recommendations.
    private nonisolated static func filteredGroups(_ input: RegroupInput) -> [SimilarityGroup] {
        let raw = input.fixed ?? input.graph?.groups(threshold: input.tolerance, maxSpan: Tolerance.maxGroupSpan) ?? []
        return raw.compactMap { g -> SimilarityGroup? in
            let members = g.members.filter { !input.excluded.contains($0) }
            guard members.count > 1 else { return nil }
            let group = SimilarityGroup(members: members)
            return input.confirmed.contains(group.id) ? nil : group
        }
    }

    private nonisolated static func computeGroups(_ input: RegroupInput) -> ([SimilarityGroup], [String: Set<AssetID>]) {
        var groups = filteredGroups(input)
        var recommended: [String: Set<AssetID>] = [:]
        if input.fixed != nil {
            for g in groups { recommended[g.id] = DuplicateFinder.recommendedKeeps(g, info: input.assets) }
            // Biggest wins first: bytes freed if the recommendation is accepted.
            func reclaimable(_ g: SimilarityGroup) -> Int64 {
                g.members.filter { !recommended[g.id, default: []].contains($0) }.reduce(0) { $0 + (input.assets[$1]?.fileSize ?? 0) }
            }
            groups.sort { reclaimable($0) > reclaimable($1) }
        } else {
            let recommender = Recommender()
            for g in groups { recommended[g.id] = recommender.recommendedKeeps(g, info: input.assets, signals: input.signals) }
        }
        return (groups, recommended)
    }

    /// Multi-pass progress: groups left at each preset (background, debounced).
    func refreshPresetCounts() {
        guard !isDuplicates else { return }
        countsTask?.cancel()
        let inputs = Tolerance.Preset.allCases.compactMap { p in regroupInput(tolerance: p.threshold).map { (p, $0) } }
        guard !inputs.isEmpty else { return }
        countsTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let counts = await Task.detached(priority: .utility) {
                Dictionary(uniqueKeysWithValues: inputs.map { ($0.0, Self.filteredGroups($0.1).count) })
            }.value
            guard !Task.isCancelled else { return }
            presetCounts = counts
        }
    }

    private func apply(_ result: ([SimilarityGroup], [String: Set<AssetID>])) {
        session = ReviewSession(groups: result.0, recommended: result.1, favorites: favorites)
        appliedDeletions = []
        appliedConfirmed = []
        appliedReviewed = []
        priorReviewed = Set(app?.reviewed.keys ?? [:].keys)
        refreshPresetCounts()
    }

    /// Members of `group` already kept in an earlier pass.
    func keptEarlier(in group: SimilarityGroup) -> [AssetID] { group.members.filter(priorReviewed.contains) }

    func scores(for group: SimilarityGroup) -> [AssetID: Recommender.Scored] {
        Dictionary(Recommender().score(group, signals: signals).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Review edits (Phase 4)

    /// Apply an edit to the review session, then push confirmed deletions to the bin.
    func edit(_ change: (inout ReviewSession) -> Void) {
        change(&session)
        sync()
    }

    private func sync() {
        guard let app else { return }
        let pending = session.pendingDeletions
        let now = Set(pending)
        let added = pending.filter { !appliedDeletions.contains($0) }
        let removed = appliedDeletions.subtracting(now)
        appliedDeletions = now
        app.updateBin(add: added, remove: removed)

        // Persist each confirmed group by its KEPT members: once the rejects are in
        // the bin (or deleted) that's exactly the group a rescan would rebuild,
        // so it stays hidden. A looser pass that merges it with new photos yields a
        // different ID and is shown again — the multi-pass workflow.
        let confirmed = Set(session.groups.filter { session.confirmed.contains($0.id) }.map { group in
            SimilarityGroup(members: group.members.filter { session.isKept($0, in: group) }).id
        })
        app.updateConfirmed(add: confirmed.subtracting(appliedConfirmed), remove: appliedConfirmed.subtracting(confirmed))
        if confirmed != appliedConfirmed { refreshPresetCounts() }
        appliedConfirmed = confirmed

        // Multi-pass memory: every photo kept in a confirmed group, with this pass's tolerance.
        // Photos already reviewed before this session keep their original record.
        let kept = Set(session.groups.filter { session.confirmed.contains($0.id) }.flatMap { group in
            group.members.filter { session.isKept($0, in: group) }
        }).subtracting(priorReviewed)
        let passTolerance: Float = isDuplicates ? 0 : tolerance
        let newlyKept = kept.subtracting(appliedReviewed)
        app.updateReviewed(add: Dictionary(uniqueKeysWithValues: newlyKept.map { ($0, passTolerance) }),
                           remove: appliedReviewed.subtracting(kept))
        appliedReviewed = kept
    }
}
