import Foundation

/// Assets the user has decided to delete but not yet sent to Photos.
/// Shown as "To Delete" in the sidebar; committed in one batch (PLAN.md Phase 5).
public struct PendingBin: Sendable, Codable, Equatable {
    public private(set) var items: [AssetID] = []
    private var index: Set<AssetID> = []

    public init(_ items: [AssetID] = []) { add(items) }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }
    public func contains(_ id: AssetID) -> Bool { index.contains(id) }

    public mutating func add(_ ids: [AssetID]) {
        for id in ids where index.insert(id).inserted { items.append(id) }
    }

    public mutating func restore(_ ids: Set<AssetID>) {
        guard !ids.isEmpty else { return }
        items.removeAll { ids.contains($0) }
        index.subtract(ids)
    }

    public mutating func restoreAll() {
        items = []
        index = []
    }
}
