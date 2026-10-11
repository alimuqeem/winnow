import Foundation
import Observation
import Photos
import WinnowCore

enum SidebarItem: Hashable {
    case collection(String)
    case toDelete
    case videos
    case duplicates
}

/// App-wide state: library, cache, per-collection scans and the pending-deletion bin.
@MainActor
@Observable
final class AppModel {
    let library = PhotoLibraryService()
    let cache = AnalysisCache()

    var selection: SidebarItem? = {
        let args = ProcessInfo.processInfo.arguments
        if args.contains(where: { $0 == "--autocompare" || $0 == "--videos" }) { return .videos }
        if args.contains("--dupes") { return .duplicates }
        return .collection(PhotoLibraryService.allPhotosID)
    }()
    private(set) var bin = PendingBin()
    private(set) var confirmedGroups: Set<String> = []
    /// Photos kept in confirmed groups, with the tolerance of that pass (multi-pass review).
    private(set) var reviewed: [AssetID: Float] = [:]
    /// Assets moved to Recently Deleted this session; excluded until the next rescan.
    private(set) var removed: Set<AssetID> = []
    /// Registry only (created lazily from view bodies), so not observed.
    @ObservationIgnored private var scans: [String: ScanModel] = [:]
    /// Compress Videos tool (Phase 6).
    @ObservationIgnored lazy var videos = VideoModel(app: self)
    /// The scan whose review is on screen; receives ⌘Z / ⇧⌘Z from the menu.
    var activeReview: ScanModel?

    /// Original file sizes, filled lazily (PHAssetResource lookups are slow-ish).
    private(set) var fileSizes: [AssetID: Int64] = [:]
    @ObservationIgnored private var sizeRequests = Set<AssetID>()

    @ObservationIgnored private var startTask: Task<Void, Never>?

    /// Idempotent; every caller awaits the same start-up.
    func start() async {
        if startTask == nil {
            startTask = Task {
                Task.detached(priority: .utility) { VideoModel.clearLeftovers() }
                bin = PendingBin(await cache.pending())
                confirmedGroups = await cache.confirmedGroups()
                reviewed = await cache.reviewedAssets()
                await library.requestAccess()
            }
        }
        await startTask?.value
    }

    static let duplicatesID = "duplicates"

    /// The whole-library exact-duplicate pass, shown like a collection.
    var duplicatesCollection: LibraryCollection {
        LibraryCollection(id: Self.duplicatesID, title: "Duplicates", kind: .allPhotos,
                          count: library.photoCount + library.videoCount)
    }

    func scan(for collection: LibraryCollection) -> ScanModel {
        if let existing = scans[collection.id] { return existing }
        let model = ScanModel(collectionID: collection.id, title: collection.title, app: self)
        scans[collection.id] = model
        return model
    }

    func collection(withID id: String) -> LibraryCollection? {
        if id == Self.duplicatesID { return duplicatesCollection }
        func find(_ list: [LibraryCollection]) -> LibraryCollection? {
            for c in list {
                if c.id == id { return c }
                if let hit = find(c.children) { return hit }
            }
            return nil
        }
        return find(library.collections)
    }

    // MARK: - Pending bin & confirmed groups (persisted)

    func updateBin(add: [AssetID], remove: Set<AssetID>) {
        guard !add.isEmpty || !remove.isEmpty else { return }
        bin.restore(remove)
        bin.add(add)
        persistBin()
        ensureSizes(add)
    }

    func restore(_ ids: Set<AssetID>) {
        bin.restore(ids)
        persistBin()
    }

    func restoreAll() {
        bin.restoreAll()
        persistBin()
    }

    func updateReviewed(add: [AssetID: Float], remove: Set<AssetID>) {
        guard !add.isEmpty || !remove.isEmpty else { return }
        for id in remove { reviewed[id] = nil }
        reviewed.merge(add) { _, new in new }
        let cache = cache
        Task { await cache.setReviewed(add: add, remove: remove) }
    }

    func updateConfirmed(add: Set<String>, remove: Set<String>) {
        guard !add.isEmpty || !remove.isEmpty else { return }
        confirmedGroups.subtract(remove)
        confirmedGroups.formUnion(add)
        let cache = cache
        Task { await cache.setConfirmed(add: add, remove: remove) }
    }

    /// Sends the whole bin to Photos' Recently Deleted in one batch.
    /// On failure (including the user declining the system prompt) everything stays pending.
    func commitBin() async throws {
        let ids = bin.items
        guard !ids.isEmpty else { return }
        let missing = try await library.moveToRecentlyDeleted(ids)
        if !missing.isEmpty { Log.photos.notice("\(missing.count) pending assets were already gone") }
        bin.restore(Set(ids))
        removed.formUnion(ids)
        persistBin()
        // Deleted photos must not reappear in open scans' groups.
        for scan in scans.values where scan.phase == .ready { scan.regroup() }
    }

    /// Writes are chained so the last state always lands last.
    @ObservationIgnored private var persistTask: Task<Void, Never>?

    private func persistBin() {
        let items = bin.items, cache = cache, previous = persistTask
        persistTask = Task {
            await previous?.value
            await cache.setPending(items)
        }
    }

    /// Wait for pending writes (used before quitting).
    func flush() async { await persistTask?.value }

    // MARK: - File sizes

    func ensureSizes(_ ids: [AssetID]) {
        let wanted = ids.filter { fileSizes[$0] == nil && !sizeRequests.contains($0) }
        guard !wanted.isEmpty else { return }
        sizeRequests.formUnion(wanted)
        Task {
            let sizes = await Task.detached(priority: .utility) {
                PhotoLibraryService.assets(wanted).map { (AssetID($0.localIdentifier), PhotoLibraryService.fileSize(of: $0)) }
            }.value
            for (id, size) in sizes { fileSizes[id] = size }
        }
    }

    func totalSize(_ ids: some Sequence<AssetID>) -> Int64 {
        ids.reduce(0) { $0 + (fileSizes[$1] ?? 0) }
    }
}
