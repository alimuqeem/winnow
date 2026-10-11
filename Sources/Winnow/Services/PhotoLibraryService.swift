import AppKit
import AVFoundation
import Foundation
import Observation
import Photos
import WinnowCore

/// The only code that talks to PhotoKit (PLAN.md §3).
@MainActor
@Observable
final class PhotoLibraryService: NSObject {
    private(set) var authorization: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var photoCount = 0
    private(set) var videoCount = 0
    private(set) var collections: [LibraryCollection] = []
    /// Bumped on every Photos library change so views can refresh.
    private(set) var changeCounter = 0

    @ObservationIgnored private let imageManager = PHCachingImageManager()
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var reloadTask: Task<Void, Never>?

    var isAuthorized: Bool { authorization == .authorized || authorization == .limited }

    var statusLine: String {
        switch authorization {
        case .authorized, .limited: "\(photoCount.formatted()) photos, \(videoCount.formatted()) videos"
        case .denied, .restricted: "Photos access denied: enable Winnow in System Settings › Privacy & Security › Photos"
        default: "Requesting Photos access…"
        }
    }

    func requestAccess() async {
        authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard isAuthorized else {
            Log.app.error("Photos access not granted: \(self.authorization.rawValue)")
            return
        }
        if !observing {
            PHPhotoLibrary.shared().register(self)
            observing = true
        }
        await reload()
        Log.app.notice("authorized: \(self.photoCount) photos, \(self.videoCount) videos, \(self.collections.count) top-level collections")
    }

    func reload() async {
        let (photos, videos, tree) = await Task.detached(priority: .userInitiated) {
            (PHAsset.fetchAssets(with: .image, options: nil).count,
             PHAsset.fetchAssets(with: .video, options: nil).count,
             Self.buildCollections())
        }.value
        photoCount = photos
        videoCount = videos
        collections = tree
    }

    // MARK: - Collections (Phase 1)

    nonisolated static let allPhotosID = "all"

    /// [All Photos] + smart albums with photos + user albums/folders (recursive).
    nonisolated private static func buildCollections() -> [LibraryCollection] {
        let all = LibraryCollection(id: allPhotosID, title: "All Photos", kind: .allPhotos,
                                    count: PHAsset.fetchAssets(with: .image, options: nil).count)

        var smart: [LibraryCollection] = []
        let smartFetch = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: nil)
        smartFetch.enumerateObjects { collection, _, _ in
            // All Photos is shown separately; Recently Deleted isn't readable.
            guard collection.assetCollectionSubtype != .smartAlbumUserLibrary else { return }
            let count = PHAsset.fetchAssets(in: collection, options: imagesOnly()).count
            guard count > 0 else { return }
            smart.append(LibraryCollection(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled",
                                           kind: .smartAlbum, count: count))
        }
        smart.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }

        let userTop = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        let albums = children(of: userTop)

        return [all,
                LibraryCollection(id: "section.smart", title: "Smart Albums", kind: .folder, count: smart.count, children: smart),
                LibraryCollection(id: "section.albums", title: "Albums", kind: .folder, count: albums.count, children: albums)]
    }

    nonisolated private static func children(of fetch: PHFetchResult<PHCollection>) -> [LibraryCollection] {
        var out: [LibraryCollection] = []
        fetch.enumerateObjects { collection, _, _ in
            if let album = collection as? PHAssetCollection {
                let count = PHAsset.fetchAssets(in: album, options: imagesOnly()).count
                out.append(LibraryCollection(id: album.localIdentifier, title: album.localizedTitle ?? "Untitled",
                                             kind: .album, count: count))
            } else if let list = collection as? PHCollectionList {
                let kids = children(of: PHCollection.fetchCollections(in: list, options: nil))
                out.append(LibraryCollection(id: list.localIdentifier, title: list.localizedTitle ?? "Folder",
                                             kind: .folder, count: kids.count, children: kids))
            }
        }
        return out
    }

    nonisolated private static func imagesOnly() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return options
    }

    // MARK: - Assets

    /// Photos (images only) in a collection, oldest first, plus their modification dates.
    nonisolated static func fetchPhotos(in collectionID: String) -> [(asset: PHAsset, info: AssetInfo, modified: Date)] {
        let result: PHFetchResult<PHAsset>
        if collectionID == allPhotosID {
            result = PHAsset.fetchAssets(with: imagesOnly())
        } else if let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [collectionID], options: nil).firstObject {
            result = PHAsset.fetchAssets(in: collection, options: imagesOnly())
        } else {
            return []
        }
        var out: [(PHAsset, AssetInfo, Date)] = []
        out.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            out.append((asset, info(for: asset), asset.modificationDate ?? asset.creationDate ?? .distantPast))
        }
        return out
    }

    nonisolated static func info(for asset: PHAsset) -> AssetInfo {
        AssetInfo(id: AssetID(asset.localIdentifier),
                  kind: asset.mediaType == .video ? .video : .photo,
                  creationDate: asset.creationDate ?? .distantPast,
                  pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
                  isFavorite: asset.isFavorite, hasEdits: asset.hasAdjustments)
    }

    nonisolated static func assets(_ ids: [AssetID]) -> [PHAsset] {
        guard !ids.isEmpty else { return [] }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        var out: [PHAsset] = []
        fetch.enumerateObjects { asset, _, _ in out.append(asset) }
        return out
    }

    /// Original file size via the asset's primary resource. Slow-ish (~1 ms); call lazily.
    nonisolated static func fileSize(of asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        let primary = resources.first { $0.type == .photo || $0.type == .fullSizePhoto } ?? resources.first
        return (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    // MARK: - Images

    /// Calls `handler` one or more times (fast degraded image, then final). Returns a cancel token.
    @discardableResult
    func requestImage(_ id: AssetID, side: CGFloat, highQuality: Bool = false,
                      handler: @escaping (NSImage) -> Void) -> PHImageRequestID? {
        guard let asset = Self.assets([id]).first else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = highQuality ? .highQualityFormat : .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let target = CGSize(width: side * scale, height: side * scale)
        return imageManager.requestImage(for: asset, targetSize: target, contentMode: .aspectFit, options: options) { image, _ in
            if let image { handler(image) }
        }
    }

    func cancel(_ request: PHImageRequestID) { imageManager.cancelImageRequest(request) }

    /// A CGImage for analysis (see `AnalysisService.imageSide`).
    /// With `network: false` this returns nil for iCloud-only photos instead of
    /// downloading, so the scan can do all local photos first (PLAN.md Phase 2).
    nonisolated static func analysisImage(for asset: PHAsset, side: CGFloat = 512, network: Bool = true) async -> CGImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = network
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFit, options: options) { image, info in
                // highQualityFormat delivers exactly once.
                continuation.resume(returning: image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            }
        }
    }

    // MARK: - Videos (Phase 6)

    struct VideoRecord: Sendable, Identifiable, Codable {
        let id: AssetID
        let facts: VideoFacts
        let creationDate: Date
        let isFavorite: Bool
        var isLocal: Bool
    }

    /// Every video with its size and the facts VideoPlan needs. ~1 ms per video
    /// (resource lookup), so call off the main thread.
    nonisolated static func fetchVideos() -> [VideoRecord] {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
        let result = PHAsset.fetchAssets(with: options)
        // Resource lookups dominate (~4 ms each); spread them across cores.
        let count = result.count
        let slots = UnsafeMutableBufferPointer<VideoRecord?>.allocate(capacity: count)
        slots.initialize(repeating: nil)
        defer { slots.deallocate() }
        nonisolated(unsafe) let buffer = slots
        DispatchQueue.concurrentPerform(iterations: count) { index in
            let asset = result.object(at: index)
            let resources = PHAssetResource.assetResources(for: asset)
            let primary = resources.first { $0.type == .video } ?? resources.first
            let size = (primary?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
            let local = (primary?.value(forKey: "locallyAvailable") as? NSNumber)?.boolValue ?? true
            let sub = asset.mediaSubtypes
            buffer[index] = (VideoRecord(
                id: AssetID(asset.localIdentifier),
                facts: VideoFacts(width: asset.pixelWidth, height: asset.pixelHeight, duration: asset.duration,
                                  fileSize: size,
                                  isSlowMo: sub.contains(.videoHighFrameRate),
                                  isTimeLapse: sub.contains(.videoTimelapse),
                                  isCinematic: sub.contains(.videoCinematic),
                                  isEdited: asset.hasAdjustments),
                creationDate: asset.creationDate ?? .distantPast,
                isFavorite: asset.isFavorite,
                isLocal: local))
        }
        return slots.compactMap { $0 }
    }

    /// The original video as an AVAsset, downloading from iCloud if needed.
    nonisolated static func avAsset(for id: AssetID, network: Bool = true,
                                    progress: (@Sendable (Double) -> Void)? = nil) async -> AVAsset? {
        guard let asset = assets([id]).first else { return nil }
        let options = PHVideoRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = network
        options.progressHandler = { value, _, _, _ in progress?(value) }
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }

    /// Replaces originals with compressed files in ONE atomic change: each new
    /// asset gets the original's date, location, favourite flag and user albums,
    /// and the originals go to Recently Deleted. macOS asks once; if the user
    /// declines, nothing at all changes (no duplicates left behind).
    func replaceVideos(_ replacements: [(original: AssetID, file: URL)]) async throws {
        let originals = Dictionary(uniqueKeysWithValues: Self.assets(replacements.map(\.original)).map { (AssetID($0.localIdentifier), $0) })
        var albums: [AssetID: [PHAssetCollection]] = [:]
        var names: [AssetID: String] = [:]
        for (id, asset) in originals {
            var list: [PHAssetCollection] = []
            PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil).enumerateObjects { c, _, _ in
                if c.canPerform(.addContent) { list.append(c) }
            }
            albums[id] = list
            if let name = PHAssetResource.assetResources(for: asset).first?.originalFilename {
                names[id] = (name as NSString).deletingPathExtension + ".mov"
            }
        }
        let jobs = replacements.compactMap { r in originals[r.original].map { (r.original, $0, r.file) } }
        guard !jobs.isEmpty else { return }

        try await PHPhotoLibrary.shared().performChanges {
            for (id, original, file) in jobs {
                let create = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = names[id]
                create.addResource(with: .video, fileURL: file, options: options)
                create.creationDate = original.creationDate
                create.location = original.location
                create.isFavorite = original.isFavorite
                if let placeholder = create.placeholderForCreatedAsset {
                    for album in albums[id] ?? [] {
                        PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                    }
                }
            }
            PHAssetChangeRequest.deleteAssets(jobs.map(\.1) as NSArray)
        }
        Log.photos.notice("replaced \(jobs.count) videos with compressed copies")
    }

    // MARK: - Deletion (Phase 5)

    /// Moves assets to Photos' Recently Deleted in ONE change block, so macOS
    /// shows one confirmation. Throws if the user declines.
    /// Returns the IDs that no longer existed (already deleted elsewhere).
    func moveToRecentlyDeleted(_ ids: [AssetID]) async throws -> [AssetID] {
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: ids.map(\.rawValue), options: nil)
        var found = Set<String>()
        fetch.enumerateObjects { asset, _, _ in found.insert(asset.localIdentifier) }
        let missing = ids.filter { !found.contains($0.rawValue) }
        guard fetch.count > 0 else { return missing }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(fetch)
        }
        Log.photos.notice("moved \(fetch.count) assets to Recently Deleted")
        return missing
    }
}

extension PhotoLibraryService: PHPhotoLibraryChangeObserver {
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor in
            // Debounce: Photos sends bursts of changes (iCloud sync, our own deletes).
            self.reloadTask?.cancel()
            self.reloadTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.changeCounter += 1
                await self.reload()
            }
        }
    }
}
