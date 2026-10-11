import SwiftUI
import WinnowCore

/// A collection before, during and after a scan (PLAN.md Phases 1–3).
struct CollectionView: View {
    @Environment(AppModel.self) private var app
    let collection: LibraryCollection
    @State private var reviewing = false

    var body: some View {
        let scan = app.scan(for: collection)
        Group {
            if reviewing, scan.phase == .ready {
                ReviewView(scan: scan) { reviewing = false }
            } else {
                switch scan.phase {
                case .idle, .failed:
                    preScan(scan)
                case .fetching, .analysing, .grouping:
                    progress(scan)
                case .ready:
                    GroupsOverview(scan: scan) { index in
                        scan.edit { $0.goTo(groupAt: index) }
                        reviewing = true
                    }
                }
            }
        }
        .navigationTitle(collection.title)
        .onChange(of: collection.id) { reviewing = false }
        // `--autoreview`: scan and open the review straight away (screenshots / manual testing).
        .task {
            guard ProcessInfo.processInfo.arguments.contains("--autoreview") else { return }
            if scan.phase == .idle { scan.start() }
            while scan.phase != .ready { try? await Task.sleep(for: .milliseconds(200)) }
            reviewing = !scan.groups.isEmpty
        }
    }

    private func preScan(_ scan: ScanModel) -> some View {
        ZStack {
            PreviewGrid(collectionID: scan.isDuplicates ? PhotoLibraryService.allPhotosID : collection.id)
                .opacity(0.35)
                .allowsHitTesting(false)
            VStack(spacing: 10) {
                Image(systemName: "photo.stack").font(.system(size: 40)).foregroundStyle(.tint)
                Text(collection.title).font(.title3.bold())
                Text(scan.isDuplicates ? "Exact copies anywhere in your library, any date: photos and videos"
                                       : "\(collection.count.formatted()) photos").foregroundStyle(.secondary)
                Button {
                    scan.start()
                } label: {
                    Label(scan.isDuplicates ? "Find Duplicates" : "Scan for Similar Photos", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                Text("First scans of large libraries take a while; rescans are seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                if case let .failed(message) = scan.phase {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(28)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .shadow(radius: 12)
        }
    }

    private func progress(_ scan: ScanModel) -> some View {
        VStack(spacing: 14) {
            switch scan.phase {
            case let .analysing(done, total) where total > 0:
                ProgressView(value: Double(done), total: Double(total)) {
                    Text("Analysing \(done.formatted()) of \(total.formatted()) photos")
                    if scan.downloadingCount > 0 {
                        Text("Downloading \(scan.downloadingCount.formatted()) iCloud-only photos (limited by network)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } currentValueLabel: {
                    if let eta = scan.eta {
                        Text("About \(Duration.seconds(eta).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))) left")
                    }
                }
                .frame(maxWidth: 420)
            case .grouping:
                ProgressView("Grouping similar photos…")
            default:
                ProgressView("Reading library…")
            }
            Button("Cancel") { scan.cancel() }
            Text("Analysis is saved as it goes. Quitting now resumes where it left off.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Lightweight grid of the collection's photos (shown behind the scan card).
private struct PreviewGrid: View {
    let collectionID: String
    @State private var ids: [AssetID] = []

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 4)], spacing: 4) {
                ForEach(ids, id: \.self) { id in
                    ThumbnailView(id: id, side: 120).aspectRatio(1, contentMode: .fit)
                }
            }
            .padding(4)
        }
        .task(id: collectionID) {
            let id = collectionID
            ids = await Task.detached { PhotoLibraryService.fetchPhotos(in: id).suffix(300).map(\.info.id) }.value.reversed()
        }
    }
}

/// After a scan: tolerance controls + one card per group (PLAN.md Phase 3).
private struct GroupsOverview: View {
    @Environment(AppModel.self) private var app
    @Bindable var scan: ScanModel
    let open: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if scan.groups.isEmpty {
                ContentUnavailableView("No similar photos", systemImage: "checkmark.seal",
                                       description: Text("Nothing to review at this tolerance. Try loosening it."))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                        ForEach(Array(scan.groups.enumerated()), id: \.element.id) { index, group in
                            GroupCard(group: group, confirmed: scan.session.confirmed.contains(group.id),
                                      keptEarlier: scan.keptEarlier(in: group).count,
                                      size: scan.isDuplicates ? group.members.reduce(0) { $0 + (scan.assets[$1]?.fileSize ?? 0) } : nil)
                                .onTapGesture { open(index) }
                        }
                    }
                    .padding(12)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(scan.groups.count.formatted()) groups")
                    .font(.headline)
                Text("· \(scan.groups.reduce(0) { $0 + $1.members.count }.formatted()) photos")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Rescan") { scan.start() }
                Button {
                    open(scan.session.currentIndex)
                } label: {
                    Label("Review", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(scan.groups.isEmpty)
            }
            if scan.isDuplicates {
                Text("About \(bytes(reclaimable)) can be freed by keeping one copy of each (biggest first). The kept copy is the favourite, edited or highest-resolution one.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                toleranceControls
                passSummary
            }
            Text("\(scan.stats.photos.formatted()) photos · \(scan.stats.analysed.formatted()) analysed, \(scan.stats.cached.formatted()) from cache\(scan.stats.failed > 0 ? ", \(scan.stats.failed) unreadable" : "") · \(String(format: "%.1f", scan.stats.seconds)) s · regroup \(String(format: "%.0f", scan.regroupMillis)) ms")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(12)
    }

    /// Bytes freed if every remaining group's recommendation is accepted.
    private var reclaimable: Int64 {
        scan.groups.reduce(0) { total, g in
            total + g.members.filter { !scan.session.isRecommended($0, in: g) }.reduce(0) { $0 + (scan.assets[$1]?.fileSize ?? 0) }
        }
    }

    /// Multi-pass memory: what's been kept at each tolerance so far.
    @ViewBuilder
    private var passSummary: some View {
        let reviewed = app.reviewed.values
        if !reviewed.isEmpty {
            let presets = Tolerance.Preset.allCases
            let counts = presets.map { p in
                (p, reviewed.filter { t in t > 0 && presets.min { abs($0.threshold - t) < abs($1.threshold - t) } == p }.count)
            }.filter { $0.1 > 0 }
            let dupes = reviewed.filter { $0 == 0 }.count
            Text("Reviewed so far: " + (counts.map { "\($0.1.formatted()) photos at \($0.0.rawValue)" } + (dupes > 0 ? ["\(dupes.formatted()) in Duplicates"] : []))
                .joined(separator: " · ") + ". Kept photos are marked when a looser pass regroups them.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var toleranceControls: some View {
            HStack(spacing: 12) {
                Text("Tolerance").foregroundStyle(.secondary)
                Text("Tight").font(.caption).foregroundStyle(.secondary)
                Slider(value: $scan.tolerance, in: Tolerance.range)
                    .frame(maxWidth: 320)
                    .onChange(of: scan.tolerance) { scan.scheduleRegroup() }
                Text("Loose").font(.caption).foregroundStyle(.secondary)
                ForEach(Tolerance.Preset.allCases) { preset in
                    Button {
                        scan.tolerance = preset.threshold
                    } label: {
                        if let left = scan.presetCounts[preset] {
                            Text("\(preset.rawValue) · \(left.formatted()) left")
                        } else {
                            Text(preset.rawValue)
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(abs(scan.tolerance - preset.threshold) < 0.005 ? .accentColor : nil)
                    .help("Groups still to review at this tolerance. Do a tight pass first, then loosen.")
                }
                Spacer()
                Text(String(format: "%.2f", scan.tolerance)).monospacedDigit().foregroundStyle(.secondary)
            }
            .controlSize(.small)
    }
}

private struct GroupCard: View {
    let group: SimilarityGroup
    let confirmed: Bool
    var keptEarlier = 0
    var size: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(group.members.prefix(3), id: \.self) { id in
                    ThumbnailView(id: id, side: 100).aspectRatio(1, contentMode: .fit)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            HStack {
                Text("\(group.members.count) items").font(.caption.bold())
                if let size, size > 0 { Text(bytes(size)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if keptEarlier > 0 {
                    Text("+\(group.members.count - keptEarlier) new")
                        .font(.caption2.bold()).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.2), in: .capsule)
                        .help("\(keptEarlier) of these were kept in an earlier, tighter pass")
                }
                if confirmed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
        }
        .padding(8)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .contentShape(.rect)
    }
}
