import AppKit
import AVFoundation
import Foundation
import ImageIO
import Photos
import UniformTypeIdentifiers
import Vision
import WinnowCore

/// Headless verification against the real library (never deletes anything):
///
///   open Winnow.app --args --selftest [collection-title|all] [--out DIR] [--samples]
///
/// Writes DIR/report.txt (default ~/Library/Application Support/Winnow/selftest):
/// collections + counts, first-scan and rescan timings, groups per tolerance,
/// the edge-distance histogram, and with --samples small side-by-side JPEGs of
/// pairs from each distance band for calibrating the presets (Phase 3).
@MainActor
enum SelfTest {
    struct Args { var collection = "all"; var out: URL; var samples = false }

    static func arguments() -> Args? {
        let argv = ProcessInfo.processInfo.arguments
        guard let i = argv.firstIndex(of: "--selftest") else { return nil }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var args = Args(out: support.appendingPathComponent("Winnow/selftest", isDirectory: true))
        if i + 1 < argv.count, !argv[i + 1].hasPrefix("--") { args.collection = argv[i + 1] }
        if let o = argv.firstIndex(of: "--out"), o + 1 < argv.count { args.out = URL(fileURLWithPath: argv[o + 1]) }
        args.samples = argv.contains("--samples")
        return args
    }

    static func run(_ model: AppModel, args: Args) async {
        try? FileManager.default.createDirectory(at: args.out, withIntermediateDirectories: true)
        var lines: [String] = ["Winnow self-test \(Date().formatted(.iso8601))"]
        func log(_ s: String) { lines.append(s); Log.app.notice("selftest: \(s)") }
        defer {
            try? lines.joined(separator: "\n").appending("\n").write(to: args.out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }

        let progressURL = args.out.appendingPathComponent("progress.txt")
        func progress(_ s: String) { try? "\(Date().formatted(.iso8601)) \(s)\n".write(to: progressURL, atomically: true, encoding: .utf8) }
        progress("requesting access")
        await model.start()
        progress("library loaded")
        log("authorization: \(model.library.authorization.rawValue) (3 = authorized, 4 = limited)")
        guard model.library.isAuthorized else { log("FAIL: no Photos access"); return }
        log("library: \(model.library.photoCount) photos, \(model.library.videoCount) videos")

        if ProcessInfo.processInfo.arguments.contains("--duplicates") {
            await duplicatesTest(model, args: args, log: log, progress: progress)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--multipass") {
            await multipassTest(model, log: log, progress: progress)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--video") {
            await videoTest(log: log, progress: progress)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--icloud") {
            await profileICloud(log: log)
            return
        }
        if ProcessInfo.processInfo.arguments.contains("--profile") {
            await profile(log: log)
            return
        }

        // Phase 1: collections + counts
        func dump(_ list: [LibraryCollection], _ indent: String) {
            for c in list {
                log("\(indent)\(c.kind.rawValue) '\(c.title)' \(c.count)")
                dump(c.children, indent + "  ")
            }
        }
        dump(model.library.collections, "  ")

        let target: LibraryCollection? = args.collection == "all"
            ? model.collection(withID: PhotoLibraryService.allPhotosID)
            : findByTitle(args.collection, in: model.library.collections)
        guard let target else { log("FAIL: collection '\(args.collection)' not found"); return }

        // Phase 2: first scan (or cached) + rescan
        for pass in 1...2 {
            let scan = ScanModel(collectionID: target.id, title: target.title, app: model)
            scan.start()
            while scan.phase != .ready {
                if case let .failed(m) = scan.phase { log("FAIL: \(m)"); return }
                progress("pass \(pass): \(scan.phase) icloud=\(scan.downloadingCount)")
                try? await Task.sleep(for: .milliseconds(200))
            }
            let s = scan.stats
            log("pass \(pass) '\(target.title)': \(s.photos) photos, \(s.cached) cached, \(s.analysed) analysed (\(s.downloaded) from iCloud), \(s.failed) failed, \(s.edges) edges, \(String(format: "%.1f", s.seconds)) s")
            guard pass == 2 else { continue }

            // Phase 3: grouping per tolerance
            for t: Float in [0.04, 0.08, 0.12, 0.16, 0.20, 0.25, 0.30, 0.35, 0.45] {
                scan.tolerance = t
                scan.regroup()
                let g = scan.groups
                let sizes = g.map(\.members.count)
                log(String(format: "tolerance %.2f: %d groups, %d photos, largest %d, regroup %.1f ms",
                           t, g.count, sizes.reduce(0, +), sizes.max() ?? 0, scan.regroupMillis))
            }

            if let graph = scan.graph {
                let bands: [Float] = [0, 0.04, 0.08, 0.12, 0.16, 0.20, 0.25, 0.30, 0.35, 0.45]
                for (lo, hi) in zip(bands, bands.dropFirst()) {
                    let n = graph.edges.lazy.filter { $0.distance >= lo && $0.distance < hi }.count
                    log(String(format: "edges %.2f–%.2f: %d", lo, hi, n))
                }
                if args.samples { await writeSamples(graph, bands: bands, to: args.out, log: log) }
            }

            // Recommender sanity: favourites are always kept.
            scan.tolerance = Tolerance.Preset.similar.threshold
            scan.regroup()
            let violations = scan.groups.filter { g in
                g.members.contains { scan.session.isFavorite($0) && !scan.session.isRecommended($0, in: g) }
            }
            log("favourite-kept violations: \(violations.count)")

            // Phases 4–5: review → bin → persistence → undo, on real groups. Leaves no trace.
            let binBefore = model.bin.items, confirmedBefore = model.confirmedGroups
            let n = min(3, scan.groups.count)
            scan.edit { $0.goTo(groupAt: 0) }
            for _ in 0..<n { scan.edit { $0.confirmCurrent() } }
            let expected = scan.session.pendingDeletions
            await model.flush()
            let persisted = await model.cache.pending()
            let favouritesInBin = expected.filter { scan.session.isFavorite($0) }.count
            log("review: confirmed \(n) groups -> \(expected.count) to delete; bin \(model.bin.count) (was \(binBefore.count)), persisted \(persisted.count), confirmed ids \(model.confirmedGroups.count - confirmedBefore.count), favourites in bin \(favouritesInBin)")
            let binOK = Set(model.bin.items) == Set(binBefore).union(expected) && Set(persisted) == Set(model.bin.items)
            for _ in 0..<n { scan.edit { $0.undo() } }
            await model.flush()
            try? await Task.sleep(for: .milliseconds(300))
            let pendingAfter = await model.cache.pending(), confirmedAfter = await model.cache.confirmedGroups()
            let restored = model.bin.items == binBefore && model.confirmedGroups == confirmedBefore
                && Set(pendingAfter) == Set(binBefore) && confirmedAfter == confirmedBefore
            log("review checks: bin+persist \(binOK ? "OK" : "FAIL"), undo restores everything \(restored ? "OK" : "FAIL")")
        }
        log("OK")
    }

    /// Times each analysis stage separately on the newest photos.
    private static func profile(log: (String) -> Void) async {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        let oldest = ProcessInfo.processInfo.arguments.contains("--oldest")
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: oldest)]
        options.fetchLimit = 120
        log(oldest ? "profiling OLDEST photos" : "profiling NEWEST photos")
        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { a, _, _ in assets.append(a) }

        var images: [CGImage] = []
        var t = Date()
        for a in assets.prefix(40) { if let img = await PhotoLibraryService.analysisImage(for: a) { images.append(img) } }
        log(String(format: "image fetch (serial, highQuality): %.1f ms/photo, %d ok", Date().timeIntervalSince(t) * 1000 / 40, images.count))

        for (name, mode) in [("fastFormat", PHImageRequestOptionsDeliveryMode.fastFormat), ("highQuality", .highQualityFormat)] {
            let opts = PHImageRequestOptions()
            opts.deliveryMode = mode
            opts.resizeMode = .fast
            opts.isNetworkAccessAllowed = false
            t = Date()
            var sizes: [Int] = []
            for a in assets.suffix(40) {
                let side: Int? = await withCheckedContinuation { c in
                    PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: 512, height: 512), contentMode: .aspectFit, options: opts) { img, _ in
                        c.resume(returning: img.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }.map { max($0.width, $0.height) })
                    }
                }
                if let side { sizes.append(side) }
            }
            log(String(format: "image fetch (serial, %@, local only): %.1f ms/photo, %d/40 ok, long side min %d max %d",
                       name, Date().timeIntervalSince(t) * 1000 / 40, sizes.count, sizes.min() ?? 0, sizes.max() ?? 0))
        }
        if let first = images.first { log("analysis image size: \(first.width)x\(first.height)") }

        // Same photo analysed at 256 vs 512 px: are distances comparable?
        var small: [CGImage] = []
        for a in assets.prefix(40) { if let img = await PhotoLibraryService.analysisImage(for: a, side: 256, network: false) { small.append(img) } }
        if small.count == images.count {
            var selfDist: [Float] = [], crossBig: [Float] = [], crossSmall: [Float] = []
            var big: [FeatureVector] = [], sml: [FeatureVector] = []
            for (b, s) in zip(images, small) {
                big.append(try! await AnalysisService.analyse(b).vector)
                sml.append(try! await AnalysisService.analyse(s).vector)
            }
            for i in big.indices {
                selfDist.append(big[i].distance(to: sml[i]))
                if i > 0 { crossBig.append(big[i].distance(to: big[i - 1])); crossSmall.append(sml[i].distance(to: sml[i - 1])) }
            }
            let diffs = zip(crossBig, crossSmall).map { abs($0 - $1) }
            log(String(format: "256 vs 512 same photo: mean %.3f max %.3f; neighbour-pair distance change mean %.3f max %.3f",
                       selfDist.reduce(0, +) / Float(selfDist.count), selfDist.max() ?? 0,
                       diffs.reduce(0, +) / Float(diffs.count), diffs.max() ?? 0))
            let t = Date()
            for s in small { _ = try? await AnalysisService.analyse(s) }
            log(String(format: "all (AnalysisService) at 256: %.1f ms/photo", Date().timeIntervalSince(t) * 1000 / Double(small.count)))
        }

        func time(_ name: String, _ body: (CGImage) async throws -> Void) async {
            let t = Date()
            for img in images { try? await body(img) }
            log(String(format: "%@: %.1f ms/photo", name, Date().timeIntervalSince(t) * 1000 / Double(max(images.count, 1))))
        }
        await time("feature print") { _ = try await GenerateImageFeaturePrintRequest().perform(on: $0) }
        await time("aesthetics") { _ = try await CalculateImageAestheticsScoresRequest().perform(on: $0) }
        await time("face quality") { _ = try await DetectFaceCaptureQualityRequest().perform(on: $0) }
        await time("sharpness") { _ = AnalysisService.sharpness(of: $0) }
        await time("all (AnalysisService)") { _ = try await AnalysisService.analyse($0) }
    }

    /// Random sample: how many photos are local, and what an iCloud fetch costs per delivery mode.
    private static func profileICloud(log: (String) -> Void) async {
        let all = PHAsset.fetchAssets(with: .image, options: nil)
        var sample: [PHAsset] = []
        for _ in 0..<200 { sample.append(all.object(at: Int.random(in: 0..<all.count))) }

        func fetch(_ a: PHAsset, mode: PHImageRequestOptionsDeliveryMode, network: Bool, side: CGFloat = 512) async -> (Int, Double) {
            let o = PHImageRequestOptions()
            o.deliveryMode = mode
            o.resizeMode = .fast
            o.isNetworkAccessAllowed = network
            let t = Date()
            let px: Int = await withCheckedContinuation { c in
                var done = false
                PHImageManager.default().requestImage(for: a, targetSize: CGSize(width: side, height: side), contentMode: .aspectFit, options: o) { img, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if done || (degraded && mode == .opportunistic) { return }
                    done = true
                    c.resume(returning: img.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }.map { max($0.width, $0.height) } ?? 0)
                }
            }
            return (px, Date().timeIntervalSince(t) * 1000)
        }

        var remote: [PHAsset] = []
        var localTimes: [Double] = []
        for a in sample {
            let (px, ms) = await fetch(a, mode: .highQualityFormat, network: false)
            if px >= 256 { localTimes.append(ms) } else { remote.append(a) }
        }
        log(String(format: "random 200: %d local (avg %.1f ms), %d need iCloud", localTimes.count,
                   localTimes.reduce(0, +) / Double(max(localTimes.count, 1)), remote.count))
        guard !remote.isEmpty else { return }
        for (name, mode, side) in [("fastFormat 512", PHImageRequestOptionsDeliveryMode.fastFormat, CGFloat(512)),
                                   ("highQuality 256", .highQualityFormat, 256),
                                   ("highQuality 512", .highQualityFormat, 512)] {
            var times: [Double] = [], sizes: [Int] = []
            for a in remote.prefix(6) {
                let (px, ms) = await fetch(a, mode: mode, network: true, side: side)
                times.append(ms); sizes.append(px)
            }
            log(String(format: "iCloud %@: avg %.0f ms, max %.0f ms, sizes %@", name,
                       times.reduce(0, +) / Double(times.count), times.max() ?? 0, sizes.map(String.init).joined(separator: ",")))
        }
        let local64 = await fetch(remote[0], mode: .fastFormat, network: false)
        log("local fastFormat for an iCloud-only photo: \(local64.0) px")
    }

    // MARK: - Phase 7

    private static func waitReady(_ scan: ScanModel, progress: (String) -> Void) async -> Bool {
        scan.start()
        while scan.phase != .ready {
            if case .failed = scan.phase { return false }
            progress("\(scan.title): \(scan.phase)")
            try? await Task.sleep(for: .milliseconds(200))
        }
        return true
    }

    /// Item 4: whole-library duplicates. Reports counts, reclaimable space, the
    /// distance spread of photo pairs and (with --samples) pairs near the threshold.
    private static func duplicatesTest(_ model: AppModel, args: Args, log: (String) -> Void, progress: (String) -> Void) async {
        let scan = ScanModel(collectionID: AppModel.duplicatesID, title: "Duplicates", app: model)
        guard await waitReady(scan, progress: progress) else { log("FAIL: scan failed"); return }
        let groups = scan.groups
        let videoGroups = groups.filter { scan.assets[$0.members[0]]?.kind == .video }
        func reclaim(_ g: SimilarityGroup) -> Int64 {
            g.members.filter { !scan.session.isRecommended($0, in: g) }.reduce(0) { $0 + (scan.assets[$1]?.fileSize ?? 0) }
        }
        let total = groups.reduce(Int64(0)) { $0 + reclaim($1) }
        log(String(format: "duplicates: %d groups (%d photo, %d video), %d items, reclaimable %@, scan %.1f s",
                   groups.count, groups.count - videoGroups.count, videoGroups.count,
                   groups.reduce(0) { $0 + $1.members.count }, bytes(total), scan.stats.seconds))
        log("  video reclaimable: \(bytes(videoGroups.reduce(0) { $0 + reclaim($1) }))")
        for g in groups.prefix(8) {
            let infos = g.members.compactMap { scan.assets[$0] }
            let dates = infos.map(\.creationDate)
            log("  top: \(infos.first?.kind.rawValue ?? "?") ×\(g.members.count), frees \(bytes(reclaim(g))), dims \(Set(infos.map { "\($0.pixelWidth)x\($0.pixelHeight)" }).sorted().joined(separator: "/")), dates \(dates.min()!.formatted(date: .numeric, time: .omitted))–\(dates.max()!.formatted(date: .numeric, time: .omitted))")
        }
        for g in videoGroups.prefix(4) {
            for asset in PhotoLibraryService.assets(g.members) {
                let r = PHAssetResource.assetResources(for: asset).first { $0.type == .video }
                log("    video member: \(r?.originalFilename ?? "?") \((r?.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0) bytes, created \(asset.creationDate?.formatted(.iso8601) ?? "?"), added \((asset.value(forKey: "addedDate") as? Date)?.formatted(.iso8601) ?? "?"), duration \(String(format: "%.3f", asset.duration)), source \(asset.sourceType.rawValue)")
            }
        }
        let spanYears = groups.filter { g in
            let d = g.members.compactMap { scan.assets[$0]?.creationDate }
            return (d.max()!.timeIntervalSince(d.min()!)) > 30 * 86_400
        }.count
        log("  groups whose copies are > 30 days apart (missed by the similar-photo scan): \(spanYears)")
        log("  favourite-kept violations: \(groups.filter { g in g.members.contains { scan.session.isFavorite($0) && !scan.session.isRecommended($0, in: g) } }.count)")

        // Distance spread of photo pairs inside groups.
        let entries = await model.cache.entries(for: Dictionary(uniqueKeysWithValues: groups.flatMap(\.members)
            .filter { scan.assets[$0]?.kind == .photo }.compactMap { id in
                PhotoLibraryService.assets([id]).first.map { (id, $0.modificationDate ?? $0.creationDate ?? .distantPast) }
            }))
        // Every pair inside each group (complete linkage ⇒ all ≤ threshold).
        var bands = [0, 0, 0, 0, 0]   // =0, <0.003, <0.006, <0.01, ≤0.015
        var byBand: [Int: [(AssetID, AssetID, Float)]] = [:]
        var sameSecond = 0, pairs = 0
        for g in groups where scan.assets[g.members[0]]?.kind == .photo {
            for (x, a) in g.members.enumerated() {
                for b in g.members[(x + 1)...] {
                    guard let va = entries[a]?.vector, let vb = entries[b]?.vector else { continue }
                    let d = va.distance(to: vb)
                    let band = d == 0 ? 0 : d < 0.003 ? 1 : d < 0.006 ? 2 : d < 0.01 ? 3 : 4
                    bands[band] += 1
                    byBand[band, default: []].append((a, b, d))
                    pairs += 1
                    if let ta = scan.assets[a]?.creationDate, let tb = scan.assets[b]?.creationDate, abs(ta.timeIntervalSince(tb)) < 1 { sameSecond += 1 }
                }
            }
        }
        log("  photo pair distances: =0 \(bands[0]), <0.003 \(bands[1]), <0.006 \(bands[2]), <0.01 \(bands[3]), ≤0.015 \(bands[4]); \(sameSecond)/\(pairs) taken within 1 s of each other")
        let nearThreshold = [2, 3, 4].flatMap { (byBand[$0] ?? []).shuffled().prefix(3) }
        if args.samples {
            let dir = args.out.appendingPathComponent("samples", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (k, pair) in nearThreshold.sorted(by: { $0.2 < $1.2 }).enumerated() {
                let assets = PhotoLibraryService.assets([pair.0, pair.1])
                guard assets.count == 2, let a = await PhotoLibraryService.analysisImage(for: assets[0]),
                      let b = await PhotoLibraryService.analysisImage(for: assets[1]), let img = sideBySide(a, b) else { continue }
                let url = dir.appendingPathComponent(String(format: "dup_%d_d%.4f.jpg", k, pair.2))
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
                    CGImageDestinationFinalize(dest)
                }
            }
            log("  samples: \(dir.path)")
        }
        log("OK")
    }

    /// Item 1: confirm tight groups, loosen, check the kept photos are flagged
    /// in merged groups, then restore every piece of state.
    private static func multipassTest(_ model: AppModel, log: (String) -> Void, progress: (String) -> Void) async {
        guard let all = model.collection(withID: PhotoLibraryService.allPhotosID) else { log("FAIL: no All Photos"); return }
        let scan = ScanModel(collectionID: all.id, title: all.title, app: model)
        guard await waitReady(scan, progress: progress) else { log("FAIL: scan failed"); return }
        let reviewedBefore = model.reviewed, confirmedBefore = model.confirmedGroups, binBefore = model.bin.items

        scan.tolerance = Tolerance.Preset.nearIdentical.threshold
        scan.regroup()
        let tightGroups = scan.groups.count
        let n = min(25, tightGroups)
        for _ in 0..<n { scan.edit { $0.confirmCurrent() } }
        let kept = Set(model.reviewed.keys).subtracting(reviewedBefore.keys)
        log("tight pass: \(tightGroups) groups; confirmed \(n) -> \(kept.count) photos recorded as kept at \(Tolerance.Preset.nearIdentical.threshold)")

        scan.tolerance = Tolerance.Preset.sameMoment.threshold
        scan.regroup()
        let merged = scan.groups.filter { !scan.keptEarlier(in: $0).isEmpty }
        let flagged = Set(merged.flatMap { scan.keptEarlier(in: $0) })
        log("loose pass: \(scan.groups.count) groups; \(merged.count) contain photos kept earlier (\(flagged.count) flagged); flagged ⊆ kept: \(flagged.isSubset(of: kept) || flagged.isSubset(of: kept.union(reviewedBefore.keys)) ? "OK" : "FAIL")")
        let reconfirmed = scan.groups.filter { g in Set(g.members).isSubset(of: kept) && g.members.count > 1 }.count
        log("loose groups made only of already-kept photos (merged tight groups, worth comparing): \(reconfirmed)")

        // Preset counts are computed in the background.
        try? await Task.sleep(for: .seconds(2))
        log("groups left per preset: " + Tolerance.Preset.allCases.map { "\($0.rawValue) \(scan.presetCounts[$0].map(String.init) ?? "?")" }.joined(separator: ", "))

        // Restore.
        model.updateReviewed(add: [:], remove: Set(model.reviewed.keys).subtracting(reviewedBefore.keys))
        model.updateConfirmed(add: [], remove: model.confirmedGroups.subtracting(confirmedBefore))
        model.restore(Set(model.bin.items).subtracting(binBefore))
        await model.flush()
        try? await Task.sleep(for: .milliseconds(500))
        let dbReviewed = await model.cache.reviewedAssets(), dbConfirmed = await model.cache.confirmedGroups()
        let restored = model.reviewed == reviewedBefore && model.confirmedGroups == confirmedBefore && model.bin.items == binBefore
            && dbReviewed == reviewedBefore && dbConfirmed == confirmedBefore
        log("restore: \(restored ? "OK" : "FAIL")")
        log("OK")
    }

    // MARK: - Phase 6

    /// Library stats per quality, then compresses a few local videos to the cache
    /// folder and checks them against the originals. Never touches the library.
    private static func videoTest(log: (String) -> Void, progress: (String) -> Void) async {
        progress("reading videos")
        let t0 = Date()
        let records = await Task.detached { PhotoLibraryService.fetchVideos() }.value
        log(String(format: "read %d videos in %.1f s", records.count, Date().timeIntervalSince(t0)))
        if ProcessInfo.processInfo.arguments.contains("--list-only") { log("OK"); return }
        let total = records.reduce(Int64(0)) { $0 + $1.facts.fileSize }
        log("videos: \(records.count), \(bytes(total)), \(records.filter(\.isLocal).count) local")
        for q in VideoQuality.allCases {
            let plans = records.map { ($0, VideoPlan.make($0.facts, quality: q)) }
            let go = plans.filter { $0.1.estimatedSize != nil }
            let saving = go.reduce(Int64(0)) { $0 + $1.0.facts.fileSize - ($1.1.estimatedSize ?? 0) }
            var reasons: [String: Int] = [:]
            for (_, p) in plans { if let r = p.skipReason { reasons[r, default: 0] += 1 } }
            log("quality \(q.rawValue): \(go.count) to compress, est. saving \(bytes(saving)); skipped \(reasons.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))")
        }

        // A spread of local candidates: small, medium and large (capped for test time).
        let local = records.filter { $0.isLocal && VideoPlan.make($0.facts, quality: .medium).estimatedSize != nil && $0.facts.fileSize < 600_000_000 }
            .sorted { $0.facts.fileSize < $1.facts.fileSize }
        let picks = [local.first, local.isEmpty ? nil : local[local.count / 2], local.last].compactMap { $0 }
        if let qi = ProcessInfo.processInfo.arguments.firstIndex(of: "--vq") {
            let levels = ProcessInfo.processInfo.arguments[(qi + 1)...].compactMap(Float.init)
            for (i, record) in picks.enumerated() {
                guard let source = await PhotoLibraryService.avAsset(for: record.id, network: false) else { continue }
                let dur = try? await source.load(.duration).seconds
                for q in levels {
                    progress("vq \(q) video \(i + 1)")
                    guard let r = try? await VideoCompressor.compress(source, quality: .medium, constantQuality: q, progress: { _ in }) else {
                        log("video \(i + 1) q\(q): FAIL"); continue
                    }
                    let p = await psnr(source, AVURLAsset(url: r.url), duration: dur ?? 1)
                    log(String(format: "video %d q%.2f: %@ -> %@ (%.0f%% smaller, %.1f Mbps), %.1f s, PSNR min %.1f mean %.1f",
                               i + 1, q, bytes(record.facts.fileSize), bytes(r.size), (1 - Double(r.size) / Double(record.facts.fileSize)) * 100,
                               Double(r.size) * 8 / (dur ?? 1) / 1e6, r.seconds, p.min() ?? 0, p.reduce(0, +) / Double(max(p.count, 1))))
                    try? FileManager.default.removeItem(at: r.url)
                }
            }
            log("OK")
            return
        }
        for (i, record) in picks.enumerated() {
            progress("video \(i + 1)/\(picks.count)")
            guard let source = await PhotoLibraryService.avAsset(for: record.id, network: false) else { log("video \(i + 1): not loadable"); continue }
            do {
                let r = try await VideoCompressor.compress(source, quality: .medium, originalSize: record.facts.fileSize) { _ in }
                let out = AVURLAsset(url: r.url)
                let f = record.facts
                let saving = 1 - Double(r.size) / Double(f.fileSize)
                let durIn = try await source.load(.duration).seconds, durOut = try await out.load(.duration).seconds
                let tfOut = await VideoCompressor.transferFunction(of: out)
                let tracksIn = try await source.load(.tracks).map(\.mediaType.rawValue).filter { $0 != "meta" }.sorted()
                let droppedMeta = try await source.load(.tracks).filter { $0.mediaType == .metadata }.count
                let tracksOut = try await out.load(.tracks).map(\.mediaType.rawValue).sorted()
                let tIn = try await source.loadTracks(withMediaType: .video).first?.load(.preferredTransform)
                let tOut = try await out.loadTracks(withMediaType: .video).first?.load(.preferredTransform)
                let dateIn = try await source.load(.creationDate) != nil, dateOut = try await out.load(.creationDate) != nil
                let psnr = await psnr(source, out, duration: durIn)
                log(String(format: "video %d: %dx%d %.0f s %.0f fps%@ %@ (%.1f Mbps) -> %@ (%.0f%% smaller), %.1f s (%.1fx realtime)",
                           i + 1, f.width, f.height, f.duration, r.frameRate, r.isHDR ? " HDR" : "", bytes(f.fileSize),
                           Double(r.sourceBitrate) / 1e6, bytes(r.size), saving * 100, r.seconds, f.duration / r.seconds))
                log(String(format: "  checks: duration %.2f/%.2f %@, tracks %@ %@ (%d timed-metadata dropped), rotation %@, creation date %@, transfer %@ %@, PSNR %@",
                           durIn, durOut, abs(durIn - durOut) < 0.1 ? "OK" : "FAIL",
                           tracksOut.joined(separator: "+"), tracksIn == tracksOut ? "OK" : "FAIL (in: \(tracksIn.joined(separator: "+")))",
                           droppedMeta, tIn == tOut ? "OK" : "FAIL", dateIn == dateOut ? "OK" : "LOST",
                           tfOut ?? "none", tfOut == r.transferFunction ? "OK" : "FAIL",
                           psnr.map { String(format: "%.1f dB", $0) }.joined(separator: " ")))
                if let worst = psnr.min(), worst < 33 {
                    var shifts: [String] = []
                    for shift in [-2, -1, 1, 2] {
                        let p = await Self.psnr(source, out, duration: durIn, shiftFrames: shift, fps: r.frameRate)
                        shifts.append(String(format: "%+d: %.1f", shift, p.reduce(0, +) / Double(max(p.count, 1))))
                    }
                    let vIn = try await source.loadTracks(withMediaType: .video).first?.load(.timeRange)
                    let vOut = try await out.loadTracks(withMediaType: .video).first?.load(.timeRange)
                    log(String(format: "  low PSNR diagnosis: mean PSNR at frame shift %@; video start in %.3f out %.3f",
                               shifts.joined(separator: ", "), vIn?.start.seconds ?? -1, vOut?.start.seconds ?? -1))
                }
                try? FileManager.default.removeItem(at: r.url)
            } catch {
                log("video \(i + 1): FAIL \(error.localizedDescription)")
            }
        }
        log("OK")
    }

    /// PSNR (RGB, 8-bit) of 5 frames of `b` against `a`. With `shiftFrames`, `b` is
    /// sampled that many frames later (diagnoses timing misalignment).
    private static func psnr(_ a: AVAsset, _ b: AVAsset, duration: Double, shiftFrames: Int = 0, fps: Double = 30) async -> [Double] {
        func generator(_ asset: AVAsset) -> AVAssetImageGenerator {
            let g = AVAssetImageGenerator(asset: asset)
            g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = .zero
            g.requestedTimeToleranceAfter = .zero
            g.maximumSize = CGSize(width: 1920, height: 1920)
            return g
        }
        let ga = generator(a), gb = generator(b)
        var out: [Double] = []
        for k in 1...5 {
            let t = CMTime(seconds: duration * Double(k) / 6, preferredTimescale: 600)
            let tb = CMTime(seconds: t.seconds + Double(shiftFrames) / fps, preferredTimescale: 600)
            guard let ia = try? await ga.image(at: t).image, let ib = try? await gb.image(at: tb).image,
                  let pa = rgba(ia, width: ia.width, height: ia.height), let pb = rgba(ib, width: ia.width, height: ia.height) else { continue }
            var se = 0.0
            for i in stride(from: 0, to: pa.count, by: 4) {
                for c in 0..<3 { let d = Double(pa[i + c]) - Double(pb[i + c]); se += d * d }
            }
            let mse = se / Double(pa.count / 4 * 3)
            out.append(mse == 0 ? 99 : 10 * log10(255 * 255 / mse))
        }
        return out
    }

    private static func rgba(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var px = [UInt8](repeating: 0, count: width * height * 4)
        let ok = px.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? px : nil
    }

    private static func findByTitle(_ title: String, in list: [LibraryCollection]) -> LibraryCollection? {
        for c in list {
            if c.kind != .folder, c.title.caseInsensitiveCompare(title) == .orderedSame { return c }
            if let hit = findByTitle(title, in: c.children) { return hit }
        }
        return nil
    }

    /// Two random pairs per distance band, as small side-by-side JPEGs.
    private static func writeSamples(_ graph: SimilarityGraph, bands: [Float], to dir: URL, log: (String) -> Void) async {
        let sampleDir = dir.appendingPathComponent("samples", isDirectory: true)
        try? FileManager.default.createDirectory(at: sampleDir, withIntermediateDirectories: true)
        for (lo, hi) in zip(bands, bands.dropFirst()) {
            let picks = graph.edges.filter { $0.distance >= lo && $0.distance < hi }.shuffled().prefix(2)
            for (k, edge) in picks.enumerated() {
                let assets = PhotoLibraryService.assets([edge.a, edge.b])
                guard assets.count == 2,
                      let a = await PhotoLibraryService.analysisImage(for: assets[0], side: 256),
                      let b = await PhotoLibraryService.analysisImage(for: assets[1], side: 256),
                      let pair = sideBySide(a, b) else { continue }
                let url = sampleDir.appendingPathComponent(String(format: "d%.3f_band%.2f_%d.jpg", edge.distance, lo, k))
                if let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, pair, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
                    CGImageDestinationFinalize(dest)
                }
            }
        }
        log("samples written to \(sampleDir.path)")
    }

    private static func sideBySide(_ a: CGImage, _ b: CGImage) -> CGImage? {
        let h = 256, wa = a.width * h / max(a.height, 1), wb = b.width * h / max(b.height, 1)
        guard let ctx = CGContext(data: nil, width: wa + wb + 8, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: wa + wb + 8, height: h))
        ctx.draw(a, in: CGRect(x: 0, y: 0, width: wa, height: h))
        ctx.draw(b, in: CGRect(x: wa + 8, y: 0, width: wb, height: h))
        return ctx.makeImage()
    }
}
