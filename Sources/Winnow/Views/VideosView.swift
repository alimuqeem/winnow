import SwiftUI
import WinnowCore

/// Compress Videos (PLAN.md Phase 6): biggest savings first, compress, compare, replace.
struct VideosView: View {
    @Environment(AppModel.self) private var app
    @State private var comparing: AssetID?
    @State private var confirmReplace = false

    var body: some View {
        let model = app.videos
        VStack(spacing: 0) {
            header(model)
            Divider()
            if !model.loaded {
                ProgressView("Reading videos…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView("Nothing to shrink", systemImage: "film",
                                       description: Text("Every video is already efficient, slo-mo, time-lapse, cinematic or edited."))
            } else {
                list(model)
            }
        }
        .navigationTitle("Compress Videos")
        .task {
            if !model.loaded { await model.load() }
            // `--autocompare`: compress the smallest local candidate and open the compare view (screenshots).
            guard ProcessInfo.processInfo.arguments.contains("--autocompare"), model.compressed.isEmpty,
                  let pick = model.candidates.filter(\.record.isLocal).min(by: { $0.record.facts.fileSize < $1.record.facts.fileSize })
            else { return }
            model.selection = [pick.id]
            model.compressSelected()
            while model.running { try? await Task.sleep(for: .milliseconds(200)) }
            comparing = model.compressed.first?.id
        }
        .overlay {
            if let id = comparing {
                VideoCompareView(model: model, startAt: id) { comparing = nil }
            }
        }
        .confirmationDialog(swapQuestion(model.compressed.count), isPresented: $confirmReplace) {
            Button(swapTitle(model.compressed.count)) { Task { await model.replaceCompressed() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Each copy keeps its date, location, favourite and albums. Originals go to Photos › Recently Deleted for 30 days. Saves \(bytes(model.compressedSaving)).")
        }
    }

    private func header(_ model: VideoModel) -> some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.loaded ? "\(model.candidates.count.formatted()) videos can shrink · save about \(bytes(model.estimatedSaving))" : "Reading your videos…")
                        .font(.headline)
                    Text(!model.loaded ? "Sizes come from Photos; nothing is changed until you replace." : "\(model.skippedCount.formatted()) skipped (already efficient, slo-mo, time-lapse, cinematic or edited)\(model.savedThisSession > 0 ? " · saved \(bytes(model.savedThisSession)) so far" : ""). Estimates are rough; real sizes depend on content.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if model.loading && model.loaded {
                    ProgressView().controlSize(.small).help("Refreshing from Photos…")
                }
                Picker("Quality", selection: $model.quality) {
                    ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                .help("Low = smallest files · Medium = hard to tell apart · High = nearly identical to the original")
                .disabled(model.running)
            }
            HStack {
                Button("Select All") { model.selection = Set(model.candidates.filter { $0.compressedURL == nil }.map(\.id)) }
                Button("Select None") { model.selection = [] }
                Spacer()
                if model.running {
                    Button("Stop") { model.cancel() }
                } else {
                    Button {
                        model.compressSelected()
                    } label: {
                        Label("Compress \(model.selection.count) Selected", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    .disabled(model.selection.isEmpty)
                }
                Button {
                    comparing = model.compressed.first?.id
                } label: {
                    Label("Compare", systemImage: "rectangle.split.2x1")
                }
                .disabled(model.compressed.isEmpty)
                Button {
                    confirmReplace = true
                } label: {
                    Label(swapTitle(model.compressed.count), systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(model.compressed.isEmpty || model.running)
            }
            .controlSize(.small)
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(12)
    }

    private func list(_ model: VideoModel) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { item in
                    VideoRow(item: item, selected: model.selection.contains(item.id)) {
                        if model.selection.contains(item.id) { model.selection.remove(item.id) } else { model.selection.insert(item.id) }
                    } compare: {
                        comparing = item.id
                    } discard: {
                        model.discard(item.id)
                    }
                    Divider()
                }
            }
        }
    }
}

private struct VideoRow: View {
    let item: VideoModel.Item
    let selected: Bool
    let toggle: () -> Void
    let compare: () -> Void
    let discard: () -> Void

    var body: some View {
        let f = item.record.facts
        HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { selected }, set: { _ in toggle() }))
                .labelsHidden()
                .disabled(item.plan.estimatedSize == nil || item.compressedURL != nil || isDone)
            ThumbnailView(id: item.id, side: 64)
                .frame(width: 64, height: 44)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.record.creationDate.formatted(date: .abbreviated, time: .shortened))
                HStack(spacing: 8) {
                    Text("\(f.width)×\(f.height)")
                    Text(Duration.seconds(f.duration).formatted(.time(pattern: f.duration >= 3600 ? .hourMinuteSecond : .minuteSecond)))
                    if !item.record.isLocal { Label("iCloud", systemImage: "icloud").labelStyle(.titleAndIcon) }
                    if item.record.isFavorite { Image(systemName: "heart.fill").foregroundStyle(.red) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .frame(width: 210, alignment: .leading)
            Text(bytes(f.fileSize)).monospacedDigit().frame(width: 80, alignment: .trailing)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            result.frame(width: 190, alignment: .leading)
            Spacer()
            actions
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(.rect)
        .onTapGesture(count: 2) { if item.compressedURL != nil { compare() } }
    }

    private var isDone: Bool { if case .replaced = item.status { true } else { false } }

    @ViewBuilder
    private var result: some View {
        let original = item.record.facts.fileSize
        switch item.status {
        case .ready:
            if let est = item.plan.estimatedSize {
                Text("~\(bytes(est)) (\(percent(1 - Double(est) / Double(original))) smaller)").foregroundStyle(.secondary)
            } else {
                Text(item.plan.skipReason ?? "").foregroundStyle(.tertiary)
            }
        case let .downloading(p):
            ProgressView(value: p) { Text("Downloading from iCloud").font(.caption) }
        case let .compressing(p):
            ProgressView(value: p) { Text("Compressing \(percent(p))").font(.caption) }
        case let .compressed(_, size, _):
            Text("\(bytes(size)) (\(percent(1 - Double(size) / Double(original))) smaller)").foregroundStyle(.green).bold()
        case let .failed(message):
            Text(message).foregroundStyle(.red).lineLimit(2)
        case let .replaced(saved):
            Label("Replaced · saved \(bytes(saved))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if item.compressedURL != nil {
            HStack(spacing: 6) {
                Button("Compare", action: compare)
                Button("Discard", action: discard)
            }
            .controlSize(.small)
        }
    }
}

func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
func swapTitle(_ n: Int) -> String { n == 1 ? "Swap In 1 Smaller Copy" : "Swap In \(n.formatted()) Smaller Copies" }
func swapQuestion(_ n: Int) -> String { n == 1 ? "Swap the original for its smaller copy?" : "Swap \(n.formatted()) originals for their smaller copies?" }
func percent(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }
