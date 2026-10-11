import Foundation

/// Review state for a set of groups: what's kept, what's confirmed, undo/redo,
/// and the keyboard focus/selection inside the current group.
///
/// Nothing here deletes anything. `pendingDeletions` is what feeds the
/// "To Delete" bin; the app commits that to Photos in one batch (PLAN.md Phase 5).
public struct ReviewSession: Sendable {
    public private(set) var groups: [SimilarityGroup]
    public private(set) var recommended: [String: Set<AssetID>]   // group.id -> keeps
    public private(set) var keeps: [String: Set<AssetID>]
    public private(set) var confirmed: Set<String> = []
    public private(set) var currentIndex = 0

    /// Focused photo inside the current group, and the multi-selection (always contains the focus).
    public private(set) var focusIndex = 0
    public private(set) var selection: Set<AssetID> = []

    private var favorites: Set<AssetID>
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot: Sendable {
        var keeps: [String: Set<AssetID>]
        var confirmed: Set<String>
        var currentIndex: Int
    }

    public init(groups: [SimilarityGroup], recommended: [String: Set<AssetID>], favorites: Set<AssetID>) {
        self.groups = groups
        self.recommended = recommended
        self.keeps = recommended
        self.favorites = favorites
        resetFocus()
    }

    public var current: SimilarityGroup? { groups.indices.contains(currentIndex) ? groups[currentIndex] : nil }
    public var focusedID: AssetID? { current.flatMap { $0.members.indices.contains(focusIndex) ? $0.members[focusIndex] : nil } }
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var remainingCount: Int { groups.count - confirmed.count }
    public var isFinished: Bool { !groups.isEmpty && remainingCount == 0 }

    public func isKept(_ id: AssetID, in group: SimilarityGroup) -> Bool {
        keeps[group.id, default: []].contains(id)
    }

    public func isRecommended(_ id: AssetID, in group: SimilarityGroup) -> Bool {
        recommended[group.id, default: []].contains(id)
    }

    public func isFavorite(_ id: AssetID) -> Bool { favorites.contains(id) }

    /// True when "Delete All" on the current group would delete a favourite.
    public var currentHasFavorite: Bool { current?.members.contains(where: favorites.contains) ?? false }

    /// Assets marked for deletion in confirmed groups only.
    public var pendingDeletions: [AssetID] {
        groups.filter { confirmed.contains($0.id) }.flatMap { group in
            group.members.filter { !keeps[group.id, default: []].contains($0) }
        }
    }

    // MARK: - Navigation (not undoable)

    public mutating func goTo(groupAt index: Int) {
        guard !groups.isEmpty else { return }
        let clamped = max(0, min(index, groups.count - 1))
        if clamped != currentIndex { currentIndex = clamped; resetFocus() }
    }

    /// "Skip": move on without confirming.
    public mutating func nextGroup() { goTo(groupAt: currentIndex + 1) }
    public mutating func previousGroup() { goTo(groupAt: currentIndex - 1) }

    /// ← → move focus; with `extend` (⇧) the selection grows instead of resetting.
    public mutating func moveFocus(by delta: Int, extend: Bool = false) {
        guard let group = current, !group.members.isEmpty else { return }
        focusIndex = max(0, min(focusIndex + delta, group.members.count - 1))
        let id = group.members[focusIndex]
        if extend { selection.insert(id) } else { selection = [id] }
    }

    /// Click (or ⇧/⌘-click with `extend`) on a photo.
    public mutating func focus(_ id: AssetID, extend: Bool = false) {
        guard let index = current?.members.firstIndex(of: id) else { return }
        focusIndex = index
        if extend {
            if selection.contains(id), selection.count > 1 { selection.remove(id) } else { selection.insert(id) }
        } else {
            selection = [id]
        }
    }

    // MARK: - Edits (undoable)

    /// Space: toggle keep on the selection. If any selected photo is marked
    /// for deletion they all become kept; otherwise they all become deleted.
    public mutating func toggleKeepSelection() {
        guard let group = current else { return }
        let ids = selection.isEmpty ? Set(focusedID.map { [$0] } ?? []) : selection
        guard !ids.isEmpty else { return }
        record()
        var set = keeps[group.id, default: []]
        if ids.isSubset(of: set) { set.subtract(ids) } else { set.formUnion(ids) }
        keeps[group.id] = set
    }

    public mutating func keepAll() {
        guard let group = current else { return }
        record()
        keeps[group.id] = Set(group.members)
    }

    /// "Keep Just This": keep the selection (or focus), delete the rest.
    public mutating func keepOnlySelection() {
        guard let group = current else { return }
        let ids = selection.isEmpty ? Set(focusedID.map { [$0] } ?? []) : selection
        guard !ids.isEmpty else { return }
        record()
        keeps[group.id] = ids
    }

    /// Callers must confirm with the user first when `currentHasFavorite`.
    public mutating func deleteAll() {
        guard let group = current else { return }
        record()
        keeps[group.id] = []
    }

    public mutating func resetToRecommended() {
        guard let group = current else { return }
        record()
        keeps[group.id] = recommended[group.id] ?? []
    }

    /// Return: confirm the current group and advance to the next unconfirmed one.
    public mutating func confirmCurrent() {
        guard let group = current else { return }
        record()
        confirmed.insert(group.id)
        if let next = nextUnconfirmed(after: currentIndex) {
            currentIndex = next
            resetFocus()
        }
    }

    /// "Accept All Picks": confirm every remaining group with its current selection.
    public mutating func acceptAllSuggestions() {
        record()
        for group in groups { confirmed.insert(group.id) }
    }

    public mutating func undo() {
        guard let snap = undoStack.popLast() else { return }
        redoStack.append(snapshot())
        restore(snap)
    }

    public mutating func redo() {
        guard let snap = redoStack.popLast() else { return }
        undoStack.append(snapshot())
        restore(snap)
    }

    // MARK: - Private

    private func nextUnconfirmed(after index: Int) -> Int? {
        groups.indices.first { $0 > index && !confirmed.contains(groups[$0].id) }
            ?? groups.indices.first { !confirmed.contains(groups[$0].id) }
    }

    /// Focus the first recommended photo of the group.
    private mutating func resetFocus() {
        guard let group = current else { focusIndex = 0; selection = []; return }
        focusIndex = group.members.firstIndex { recommended[group.id, default: []].contains($0) } ?? 0
        selection = group.members.isEmpty ? [] : [group.members[focusIndex]]
    }

    private func snapshot() -> Snapshot { Snapshot(keeps: keeps, confirmed: confirmed, currentIndex: currentIndex) }

    private mutating func record() {
        undoStack.append(snapshot())
        redoStack.removeAll()
    }

    private mutating func restore(_ s: Snapshot) {
        keeps = s.keeps
        confirmed = s.confirmed
        if s.currentIndex != currentIndex { currentIndex = s.currentIndex; resetFocus() }
    }
}
