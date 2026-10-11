import AVFoundation
import AppKit
import SwiftUI
import WinnowCore

/// Original vs compressed, side by side or with a wipe slider, synced playback
/// (PLAN.md Phase 6). Space play/pause · ←→ previous/next video · W wipe · Esc close.
struct VideoCompareView: View {
    let model: VideoModel
    let startAt: AssetID
    let close: () -> Void

    @State private var index = 0
    @State private var players = SyncedPlayers()
    @State private var wipe = false
    @State private var split: CGFloat = 0.5
    @State private var confirmReplace = false
    @FocusState private var focused: Bool

    private var items: [VideoModel.Item] { model.compressed }
    private var item: VideoModel.Item? { items.indices.contains(index) ? items[index] : nil }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()
            if let item {
                HStack(spacing: 0) {
                    VStack(spacing: 10) {
                        topBar(item)
                        stage.frame(maxWidth: .infinity, maxHeight: .infinity)
                        transport
                    }
                    .padding(14)
                    Divider()
                    sidePanel(item).frame(width: 260)
                }
            } else {
                ContentUnavailableView("Nothing to compare", systemImage: "film")
                    .overlay(alignment: .topLeading) { Button("Close", action: close).padding() }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down, action: handle)
        .onAppear {
            index = items.firstIndex { $0.id == startAt } ?? 0
            focused = true
        }
        .task(id: item?.id) { await load() }
        .onDisappear { players.stop() }
        .confirmationDialog(swapQuestion(items.count), isPresented: $confirmReplace) {
            Button(swapTitle(items.count)) {
                Task {
                    players.stop()
                    await model.replaceCompressed()
                    if model.lastError == nil { close() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Originals go to Photos › Recently Deleted for 30 days.")
        }
    }

    private func load() async {
        guard let item, let url = item.compressedURL else { return }
        let original = await PhotoLibraryService.avAsset(for: item.id, network: true)
        players.load(original: original, compressed: AVURLAsset(url: url))
    }

    // MARK: - Pieces

    private func topBar(_ item: VideoModel.Item) -> some View {
        HStack {
            Button(action: close) { Image(systemName: "chevron.left") }.help("Close (Esc)")
            VStack(alignment: .leading, spacing: 0) {
                Text("\(index + 1) of \(items.count)").font(.headline)
                Text("\(bytes(item.record.facts.fileSize)), \(Duration.seconds(item.record.facts.duration).formatted(.time(pattern: .minuteSecond)))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Picker("", selection: $wipe) {
                Image(systemName: "rectangle.split.2x1").tag(false).help("Side by side")
                Image(systemName: "slider.horizontal.below.rectangle").tag(true).help("Wipe (W)")
            }
            .pickerStyle(.segmented)
            .frame(width: 110)
        }
    }

    @ViewBuilder
    private var stage: some View {
        if wipe {
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    PlayerLayerView(player: players.original)
                    PlayerLayerView(player: players.compressed)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * (1 - split)).offset(x: geo.size.width * split)
                        }
                    Rectangle().fill(.white).frame(width: 2)
                        .offset(x: geo.size.width * split - 1)
                    tag("ORIGINAL").padding(8)
                    tag("COMPRESSED").frame(maxWidth: .infinity, alignment: .trailing).padding(8)
                }
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0).onChanged { split = min(max($0.location.x / geo.size.width, 0), 1) })
            }
            .background(.black)
        } else {
            HStack(spacing: 6) {
                PlayerLayerView(player: players.original).overlay(alignment: .topLeading) { tag("ORIGINAL").padding(8) }
                PlayerLayerView(player: players.compressed).overlay(alignment: .topTrailing) { tag("COMPRESSED").padding(8) }
            }
            .background(.black)
        }
    }

    private var transport: some View {
        HStack {
            Button { players.toggle() } label: { Image(systemName: players.isPlaying ? "pause.fill" : "play.fill") }
                .buttonStyle(.plain).font(.title3)
            Slider(value: Binding(get: { players.position }, set: { players.seek(to: $0) }), in: 0...max(players.duration, 0.1))
            Text("\(Duration.seconds(players.position).formatted(.time(pattern: .minuteSecond))) / \(Duration.seconds(players.duration).formatted(.time(pattern: .minuteSecond)))")
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .overlay(alignment: .bottom) {
            Text("←→ Prev/Next · Space Play · W Wipe · Esc Close").font(.caption2).foregroundStyle(.tertiary).offset(y: 16)
        }
        .padding(.bottom, 14)
    }

    private func sidePanel(_ item: VideoModel.Item) -> some View {
        let f = item.record.facts
        let size = item.compressedSize ?? 0
        return VStack(alignment: .leading, spacing: 14) {
            section("Original") {
                row("Resolution", "\(f.width) × \(f.height)")
                row("Duration", Duration.seconds(f.duration).formatted(.time(pattern: .minuteSecond)))
                row("Size", bytes(f.fileSize))
                row("Date", item.record.creationDate.formatted(date: .abbreviated, time: .omitted))
            }
            section("Smaller copy") {
                row("Size", "\(bytes(size)) (\(percent(1 - Double(size) / Double(max(f.fileSize, 1)))) smaller)", .green)
                row("Quality", model.quality.rawValue)
            }
            section("So far") {
                row("Compared", "\(index + 1) of \(items.count)")
                row("Space freed", bytes(model.compressedSaving), .green)
            }
            Spacer()
            Button {
                confirmReplace = true
            } label: {
                Text(swapTitle(items.count)).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.green).controlSize(.large)
            Button("Discard This Copy", role: .destructive) {
                let id = item.id
                players.stop()
                model.discard(id)
                index = min(index, max(items.count - 1, 0))
            }
            .frame(maxWidth: .infinity)
            Button("Close", action: close).frame(maxWidth: .infinity)
            if let error = model.lastError { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .font(.callout)
        .padding(14)
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).font(.caption2.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    private func row(_ label: String, _ value: String, _ color: Color = .primary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(color).monospacedDigit()
        }
    }

    private func tag(_ text: String) -> some View {
        Text(text).font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 3)
            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4)).foregroundStyle(.white)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case .space: players.toggle()
        case .leftArrow: players.stop(); index = max(0, index - 1)
        case .rightArrow: players.stop(); index = min(items.count - 1, index + 1)
        case .escape: close()
        default:
            guard press.characters.lowercased() == "w" else { return .ignored }
            wipe.toggle()
        }
        return .handled
    }
}

/// Two players driven as one: the compressed one is muted and follows the original.
@MainActor
@Observable
final class SyncedPlayers {
    let original = AVPlayer()
    let compressed = AVPlayer()
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    @ObservationIgnored private var observer: Any?

    init() {
        compressed.isMuted = true
        observer = original.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds
                // Keep the pair within a frame or two.
                if self.isPlaying, abs(self.compressed.currentTime().seconds - time.seconds) > 0.08 {
                    self.compressed.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
                }
                if let item = self.original.currentItem, time >= item.duration, item.duration.isNumeric {
                    self.isPlaying = false
                }
            }
        }
    }

    func load(original asset: AVAsset?, compressed url: AVAsset) {
        stop()
        original.replaceCurrentItem(with: asset.map(AVPlayerItem.init))
        compressed.replaceCurrentItem(with: AVPlayerItem(asset: url))
        position = 0
        Task {
            duration = (try? await url.load(.duration).seconds) ?? 0
        }
    }

    func toggle() {
        if isPlaying {
            original.pause(); compressed.pause()
            isPlaying = false
        } else {
            if duration > 0, position >= duration - 0.1 { seek(to: 0) }
            compressed.seek(to: original.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero)
            original.play(); compressed.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let t = CMTime(seconds: seconds, preferredTimescale: 600)
        original.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        compressed.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
        position = seconds
    }

    func stop() {
        original.pause(); compressed.pause()
        isPlaying = false
    }
}

struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
