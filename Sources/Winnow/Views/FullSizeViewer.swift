import SwiftUI
import WinnowCore

/// Full-size compare inside the review (F / double-click). Keys stay with ReviewView:
/// ←→ move between the group's photos, Space toggles keep, Esc closes.
struct FullSizeViewer: View {
    @Environment(AppModel.self) private var app
    let scan: ScanModel
    let group: SimilarityGroup
    let id: AssetID
    let close: () -> Void

    var body: some View {
        let session = scan.session
        let index = group.members.firstIndex(of: id) ?? 0
        let info = scan.assets[id]
        let kept = session.isKept(id, in: group)
        let score = scan.scores(for: group)[id]

        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            GeometryReader { geo in
                ThumbnailView(id: id, side: max(geo.size.width, geo.size.height), highQuality: true, contentMode: .fit)
                    .background(.clear)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .overlay {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(kept ? .green : .red, lineWidth: 3)
                    }
            }
            .padding(.horizontal, 56)
            .padding(.top, 16)
            .padding(.bottom, 70)

            HStack {
                navButton("chevron.left", disabled: index == 0) { scan.edit { $0.moveFocus(by: -1) } }
                Spacer()
                navButton("chevron.right", disabled: index == group.members.count - 1) { scan.edit { $0.moveFocus(by: 1) } }
            }
            .padding(.horizontal, 12)

            VStack {
                HStack {
                    Spacer()
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title) }
                        .buttonStyle(.plain).foregroundStyle(.white.opacity(0.8))
                        .help("Close (Esc)")
                }
                Spacer()
                VStack(spacing: 4) {
                    Text("\(index + 1) / \(group.members.count)").bold()
                    HStack(spacing: 14) {
                        if let info {
                            Text("\(info.pixelWidth) × \(info.pixelHeight)")
                            Text(info.creationDate.formatted(date: .abbreviated, time: .standard))
                        }
                        if let size = app.fileSizes[id], size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        }
                        if session.isFavorite(id) { Label("Favourite", systemImage: "heart.fill").foregroundStyle(.red) }
                        if session.isRecommended(id, in: group) { Label("Best", systemImage: "star.fill").foregroundStyle(.yellow) }
                        if let score { Text("⚡︎ \(Int((score.total * 100).rounded()))%") }
                        Text(kept ? "Keeping" : "Deleting").bold().foregroundStyle(kept ? .green : .red)
                    }
                    Text("←→ Navigate · Space Toggle Keep · O Keep Just This · ↩ Confirm · Esc Close")
                        .foregroundStyle(.white.opacity(0.5))
                }
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.6), in: .rect(cornerRadius: 10))
            }
            .padding(12)
        }
    }

    private func navButton(_ icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title).padding(10)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(disabled ? 0.2 : 0.8))
        .disabled(disabled)
    }
}

struct ShortcutsOverlay: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(String, String)] = [
        ("← →", "Previous / next photo in group"),
        ("⇧← ⇧→", "Extend multi-select"),
        ("Space", "Toggle keep on selection"),
        ("Return", "Confirm group, go to next"),
        ("↑ ↓", "Previous / next group"),
        ("N", "Skip group without confirming"),
        ("A", "Accept all picks"),
        ("K", "Keep all in group"),
        ("O", "Keep just this"),
        ("D", "Delete all in group"),
        ("R", "Reset group to recommended"),
        ("F", "Full-size viewer"),
        ("I", "Show / hide score breakdown"),
        ("⌘Z  ⇧⌘Z", "Undo / redo"),
        ("?", "This overlay"),
        ("Esc", "Close viewer / back to groups"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Keyboard Shortcuts").font(.title2.bold())
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { key, action in
                    GridRow {
                        Text(key).font(.body.monospaced()).bold()
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: .rect(cornerRadius: 4))
                        Text(action)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}
