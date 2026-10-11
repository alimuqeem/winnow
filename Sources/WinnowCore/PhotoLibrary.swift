import Foundation

/// A collection shown in the sidebar (PLAN.md Phase 1).
public struct LibraryCollection: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable { case allPhotos, smartAlbum, album, folder }
    public let id: String          // PHCollection.localIdentifier, or "all"
    public var title: String
    public var kind: Kind
    public var count: Int
    public var children: [LibraryCollection]

    public init(id: String, title: String, kind: Kind, count: Int, children: [LibraryCollection] = []) {
        self.id = id; self.title = title; self.kind = kind; self.count = count; self.children = children
    }
}

/// The app's PhotoKit service implements this; tests use an in-memory fake.
/// Only the app target imports Photos, so WinnowCore stays fast to test.
public protocol PhotoLibrary: Sendable {
    func collections() async throws -> [LibraryCollection]
    func assets(in collectionID: String) async throws -> [AssetInfo]
    /// Moves assets to Photos' Recently Deleted in ONE change block
    /// (one system confirmation). Throws if the user declines.
    func moveToRecentlyDeleted(_ ids: [AssetID]) async throws
}
