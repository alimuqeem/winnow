import SwiftUI
import WinnowCore

/// The "To Delete" bin (PLAN.md Phase 5). Nothing leaves the library until
/// "Move to Recently Deleted", which sends everything in one batch.
struct TrashView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<AssetID>()
    @State private var committing = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(app.bin.count.formatted()) photos · \(ByteCountFormatter.string(fromByteCount: app.totalSize(app.bin.items), countStyle: .file))")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore Selected") {
                    app.restore(selection)
                    selection = []
                }
                .disabled(selection.isEmpty)
                Button("Restore All") { app.restoreAll() }
                    .disabled(app.bin.isEmpty)
                Button {
                    commit()
                } label: {
                    Label("Move to Recently Deleted", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(app.bin.isEmpty || committing)
            }
            .controlSize(.small)
            .padding(12)
            if let error {
                Text(error).font(.caption).foregroundStyle(.red).padding(.bottom, 6)
            }
            Divider()
            if app.bin.isEmpty {
                ContentUnavailableView("Nothing to delete", systemImage: "trash",
                                       description: Text("Photos you reject during review land here first. Moving them sends them to Photos › Recently Deleted, recoverable for 30 days."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 6)], spacing: 6) {
                        ForEach(app.bin.items, id: \.self) { id in
                            ThumbnailView(id: id, side: 130)
                                .aspectRatio(1, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 6))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Color.accentColor, lineWidth: selection.contains(id) ? 4 : 0)
                                }
                                .onTapGesture {
                                    if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
                                }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .navigationTitle("To Delete")
        .task { app.ensureSizes(app.bin.items) }
    }

    private func commit() {
        committing = true
        error = nil
        Task {
            do {
                try await app.commitBin()
            } catch {
                self.error = "Nothing was deleted: \(error.localizedDescription)"
            }
            committing = false
        }
    }
}
