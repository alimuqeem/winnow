import AppKit
import SwiftUI
import WinnowCore

/// Keyboard-first group review (PLAN.md Phase 4, keyboard map §4).
struct ReviewView: View {
    @Environment(AppModel.self) private var app
    let scan: ScanModel
    let close: () -> Void

    @FocusState private var focused: Bool
    @State private var showInfo = true
    @State private var fullSize = false
    @State private var showShortcuts = false
    @State private var confirmDeleteAll = false

    private var session: ReviewSession { scan.session }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if session.isFinished {
                finished
            } else if let group = session.current {
                tiles(group)
            }
            Divider()
            statusBar
        }
        .overlay {
            if fullSize, let group = session.current, let id = session.focusedID {
                FullSizeViewer(scan: scan, group: group, id: id) { fullSize = false }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handle)
        .onAppear {
            focused = true
            app.activeReview = scan
        }
        .onDisappear { if app.activeReview === scan { app.activeReview = nil } }
        .onChange(of: session.currentIndex) { prefetchSizes() }
        .task { prefetchSizes() }
        .sheet(isPresented: $showShortcuts) { ShortcutsOverlay() }
        .confirmationDialog("This group contains a favourite.", isPresented: $confirmDeleteAll) {
            Button("Delete All, Including Favourites", role: .destructive) { scan.edit { $0.deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Favourites are kept by default. Deleted photos go to the To Delete bin first.")
        }
    }

    // MARK: - Header (toolbar)

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: close) { Image(systemName: "chevron.left") }
                .help("Back to groups (Esc)")
            VStack(alignment: .leading, spacing: 1) {
                Text("Group \(min(session.currentIndex + 1, session.groups.count).formatted()) of \(session.groups.count.formatted())")
                    .font(.headline)
                if let group = session.current { Text(dateRange(group)).font(.caption).foregroundStyle(.secondary) }
            }
            .lineLimit(1)
            .fixedSize()
            Spacer(minLength: 8)
            // Full labels when there's room, icons (with tooltips) when not.
            ViewThatFits(in: .horizontal) {
                actions.labelStyle(.titleAndIcon)
                actions.labelStyle(.iconOnly)
            }
            .disabled(session.isFinished)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            action("Accept All Picks", "checklist", "A") { scan.edit { $0.acceptAllSuggestions() } }
            Divider().frame(height: 16)
            action("Skip", "forward.fill", "N") { scan.edit { $0.nextGroup() } }
            action("Keep All", "checkmark.circle", "K") { scan.edit { $0.keepAll() } }
            action("Keep Just This", "star", "O") { scan.edit { $0.keepOnlySelection() } }
            action("Delete All", "trash", "D") { deleteAll() }
            action("Confirm", "arrow.right", "↩") { scan.edit { $0.confirmCurrent() } }
                .buttonStyle(.borderedProminent)
            Button { showShortcuts = true } label: { Image(systemName: "keyboard") }.help("Shortcuts (?)")
        }
        .fixedSize()
    }

    private func action(_ title: String, _ icon: String, _ key: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: icon) }.help("\(title) (\(key))")
    }

    // MARK: - Tiles

    private func tiles(_ group: SimilarityGroup) -> some View {
        let scores = scan.scores(for: group)
        let n = group.members.count
        let columns = n <= 2 ? max(n, 1) : n <= 4 ? 2 : n <= 9 ? 3 : 4
        return GeometryReader { geo in
            let side = (geo.size.width - CGFloat(columns + 1) * 10) / CGFloat(columns)
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns), spacing: 10) {
                    ForEach(group.members, id: \.self) { id in
                        PhotoTile(id: id,
                                  info: scan.assets[id],
                                  kept: session.isKept(id, in: group),
                                  recommended: session.isRecommended(id, in: group),
                                  favorite: session.isFavorite(id),
                                  keptEarlier: scan.priorReviewed.contains(id),
                                  focused: session.focusedID == id,
                                  selected: session.selection.contains(id) && session.selection.count > 1,
                                  score: scan.isDuplicates ? nil : scores[id],
                                  size: app.fileSizes[id] ?? scan.assets[id]?.fileSize,
                                  showInfo: showInfo,
                                  side: side)
                        .onTapGesture(count: 2) {
                            scan.edit { $0.focus(id) }
                            fullSize = true
                        }
                        .onTapGesture {
                            let flags = NSEvent.modifierFlags
                            scan.edit { $0.focus(id, extend: flags.contains(.shift) || flags.contains(.command)) }
                            focused = true
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    // MARK: - Finished

    private var finished: some View {
        ContentUnavailableView {
            Label("All groups reviewed", systemImage: "checkmark.seal.fill")
        } description: {
            Text("\(app.bin.count.formatted()) photos are in To Delete. They stay in your library until you move them to Recently Deleted.")
        } actions: {
            Button("Review To Delete") { app.selection = .toDelete }.buttonStyle(.borderedProminent)
            Button("Back to Groups", action: close)
            Button("Undo") { scan.edit { $0.undo() } }.disabled(!session.canUndo)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Status bar

    private var statusBar: some View {
        HStack(spacing: 14) {
            if let group = session.current, !session.isFinished {
                let kept = group.members.filter { session.isKept($0, in: group) }
                let deleted = group.members.filter { !session.isKept($0, in: group) }
                Label("\(kept.count) to keep", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label("\(deleted.count) to delete", systemImage: "trash.fill").foregroundStyle(.red)
            }
            Text("\(session.remainingCount.formatted()) groups left").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            ViewThatFits(in: .horizontal) {
                hints(["←→ Navigate", "⇧←→ Multi-select", "Space Toggle", "↩ Confirm", "O Just This", "K Keep All", "D Delete All", "F Full Size", "? Help"])
                hints(["Space Toggle", "↩ Confirm", "? Help"])
                Color.clear.frame(width: 0)
            }
            Divider().frame(height: 12)
            Text("To Delete: \(app.bin.count.formatted()) · \(ByteCountFormatter.string(fromByteCount: app.totalSize(app.bin.items), countStyle: .file))")
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .font(.caption)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func hints(_ items: [String]) -> some View {
        HStack(spacing: 12) {
            ForEach(items, id: \.self) { Text($0).foregroundStyle(.tertiary) }
        }
        .fixedSize()
    }

    // MARK: - Keyboard

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        // ⌘-shortcuts (undo/redo) are handled by the menu commands.
        if press.modifiers.contains(.command) { return .ignored }
        let shift = press.modifiers.contains(.shift)
        switch press.key {
        case .leftArrow: scan.edit { $0.moveFocus(by: -1, extend: shift) }; return .handled
        case .rightArrow: scan.edit { $0.moveFocus(by: 1, extend: shift) }; return .handled
        case .upArrow: scan.edit { $0.previousGroup() }; return .handled
        case .downArrow: scan.edit { $0.nextGroup() }; return .handled
        case .space: scan.edit { $0.toggleKeepSelection() }; return .handled
        case .return: scan.edit { $0.confirmCurrent() }; return .handled
        case .escape:
            if fullSize { fullSize = false } else { close() }
            return .handled
        default: break
        }
        switch press.characters {
        case "?", "/": showShortcuts = true
        case "a", "A": scan.edit { $0.acceptAllSuggestions() }
        case "n", "N": scan.edit { $0.nextGroup() }
        case "k", "K": scan.edit { $0.keepAll() }
        case "o", "O": scan.edit { $0.keepOnlySelection() }
        case "d", "D": deleteAll()
        case "r", "R": scan.edit { $0.resetToRecommended() }
        case "f", "F": fullSize.toggle()
        case "i", "I": showInfo.toggle()
        default: return .ignored
        }
        return .handled
    }

    private func deleteAll() {
        if session.currentHasFavorite { confirmDeleteAll = true } else { scan.edit { $0.deleteAll() } }
    }

    // MARK: - Helpers

    private func prefetchSizes() {
        let upcoming = session.groups.dropFirst(session.currentIndex).prefix(5).flatMap(\.members)
        app.ensureSizes(Array(upcoming))
    }

    private func dateRange(_ group: SimilarityGroup) -> String {
        let dates = group.members.compactMap { scan.assets[$0]?.creationDate }
        guard let first = dates.min(), let last = dates.max() else { return "" }
        let day = first.formatted(date: .abbreviated, time: .omitted)
        return "\(day), \(first.formatted(date: .omitted, time: .standard)) – \(last.formatted(date: .omitted, time: .standard))"
    }
}

struct PhotoTile: View {
    let id: AssetID
    let info: AssetInfo?
    let kept: Bool
    let recommended: Bool
    let favorite: Bool
    var keptEarlier = false
    let focused: Bool
    let selected: Bool
    let score: Recommender.Scored?
    let size: Int64?
    let showInfo: Bool
    let side: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ThumbnailView(id: id, side: side, contentMode: .fit)
                .frame(height: side * 0.75)
                .background(Color.black.opacity(0.85))
                .overlay(alignment: .topLeading) { badges.padding(6) }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: kept ? "checkmark.circle.fill" : "trash.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, kept ? Color.green : Color.red)
                        .padding(6)
                }
                .opacity(kept ? 1 : 0.5)
            infoLine
        }
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(focused ? Color.accentColor : (kept ? Color.green.opacity(0.7) : Color.red.opacity(0.5)),
                              lineWidth: focused ? 4 : 2)
        }
        .overlay {
            if selected { RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)) }
        }
        .contentShape(.rect)
    }

    private var badges: some View {
        HStack(spacing: 4) {
            if recommended {
                Label("Best", systemImage: "star.fill").font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.yellow, in: .capsule).foregroundStyle(.black)
            }
            if favorite {
                Image(systemName: "heart.fill").foregroundStyle(.red)
                    .padding(4).background(.white, in: .circle)
            }
            if keptEarlier {
                Label("Kept earlier", systemImage: "checkmark.seal.fill").font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.teal, in: .capsule).foregroundStyle(.white)
                    .help("You kept this in an earlier, tighter pass")
            }
            if info?.kind == .video {
                Label("Video", systemImage: "video.fill").font(.caption2.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .capsule).foregroundStyle(.white)
            }
        }
    }

    private var infoLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if let info { Text("\(info.pixelWidth)×\(info.pixelHeight)") }
                if let size, size > 0 { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                if let info { Text(info.creationDate.formatted(date: .omitted, time: .standard)) }
                Spacer()
                if let score { Text("⚡︎ \(Int((score.total * 100).rounded()))%").bold() }
            }
            if showInfo, let score {
                Text("aesthetics \(pct(score.aesthetics)) · sharpness \(pct(score.sharpness)) · faces \(pct(score.faceQuality))")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .monospacedDigit()
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))" }
}
