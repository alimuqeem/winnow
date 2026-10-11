# Winnow — design notes

How Winnow works, why it works that way, and the numbers behind the decisions.
Measurements were taken on an Apple-silicon Mac (M1 Max) against a real
~100k-photo, ~8k-video library stored in iCloud with "Optimise Mac Storage".

## Principles

- **Work in place.** Everything goes through PhotoKit. Nothing is exported, copied
  out of the library or uploaded anywhere. Winnow makes no network calls of its own.
- **Nothing is deleted without you.** Rejects go to Winnow's own *To Delete* bin
  first. Only "Move to Recently Deleted" touches the library, in one batch (one
  macOS prompt), and Photos keeps everything for 30 days.
- **Favourites are always kept** by default. Deleting one takes an explicit action
  and a confirmation.
- **Fast enough for huge libraries.** Analyse once, cache, regroup instantly.

## Architecture

```
Winnow.app (SwiftUI, macOS 26+)
├── Services/            the only code that touches Apple media frameworks
│   ├── PhotoLibraryService   PhotoKit: collections, thumbnails, change observer, batch delete, video replace
│   ├── AnalysisService       Vision feature print, aesthetics, face quality + Laplacian sharpness
│   ├── AnalysisCache         SQLite (system libsqlite3): prints, scores, bin, review state
│   └── VideoCompressor       AVAssetReader → AVAssetWriter HEVC at constant quality
├── Model/               AppModel (bin, persistence), ScanModel (scan → group → review), VideoModel
└── Views/               sidebar, scan/overview, review, full-size viewer, To Delete, videos, compare

WinnowCore (framework, pure Swift, unit-tested)
├── SimilarityGraph      time-windowed similarity edges; groups(threshold:) is fast enough for a live slider
├── DuplicateFinder      whole-library duplicates: LSH + complete linkage (photos), metadata (videos)
├── Recommender          best-in-group choice; favourites always kept
├── ReviewSession        keep/delete state, focus & multi-select, undo/redo, pending deletions
├── PendingBin           the To Delete bin
└── VideoPlan            which videos to compress, quality tiers, estimates
```

## Similar photos

1. **One feature print per photo, at a fixed 256 px.** Vision's
   `GenerateImageFeaturePrintRequest` produces a 768-float unit vector. Its
   `distance(to:)` is the *squared* Euclidean distance, i.e. `2 − 2·dot`, so cached
   vectors are compared with a single vDSP dot product.
   - **Sizes must never be mixed.** The same photo printed at 256 px and at 512 px
     differs by ~0.4, which is more than the "Similar" tolerance.
   - **256 px is local for every photo.** At 512 px, ~35% of an optimised iCloud library
     needed a ~1 s download each (the scan dropped to ~1 photo/s). At 256 px nothing
     is downloaded. The cache is versioned and cleared if the size ever changes.
2. **Time-windowed edges.** Each photo is compared with neighbours taken within ±10
   minutes, and every edge up to the loosest tolerance (0.45) is kept. The slider just
   filters edges and reruns union-find, with a cap on how long a single group may
   span so long bursts can't chain into giant groups.
3. **Calibrated tolerances** (from viewing sample pairs at each distance):
   ≤ 0.10 duplicates and bursts · 0.10–0.22 same shot, reframed · 0.25–0.34 same
   moment, different pose or angle · > 0.35 different shots that merely share people
   or place. Presets: Near-identical 0.08, Similar 0.20, Same moment 0.35.
4. **Best-shot score** = 0.45·aesthetics + 0.30·sharpness + 0.25·face quality
   − 0.3 if it's a utility shot (receipts, screenshots). Sharpness (variance of the
   Laplacian) is normalised within each group. Ties: favourite > edited > resolution
   > file size > earlier.

**Measured:** first scan of ~104k photos took 22.6 min (~77 photos/s, about 6.5 min
per 30k); a rescan with no changes took 3.9 s; quitting mid-scan resumes where it
left off. Scans hold a `beginActivity(.userInitiated)` assertion, since a backgrounded
scan was otherwise App-Napped down to ~3 photos/s. Regrouping 100k photos takes
0.1–0.6 s, so the slider regroups off the main thread with a short debounce.

### Multi-pass review

Photos kept in a confirmed group are recorded with the tolerance of that pass.
On a looser pass, merged groups show **Kept earlier** on those photos and **+N new**
on the group card; each preset shows how many groups are left. Confirmed groups are
stored by their *kept* members, so they stay hidden after the rejects are deleted and
only come back when a looser pass merges in new photos.

## Duplicates (whole library, any date)

- **Photos.** Comparing every pair of ~100k prints is ~5·10⁹ dot products, so
  candidates come from random-hyperplane LSH (8 tables × 16 sign bits). Only vectors
  sharing a bucket are compared exactly. Groups use **complete linkage**: every pair
  in a group must be within 0.008. Single linkage chained burst frames (A≈B≈C…) into
  "duplicates" even though the first and last frames were different moments.
- **Threshold 0.008**, calibrated on viewed pairs: ≤ 0.008 were the same picture
  (re-imports, re-encodes); from ~0.010 they were already different burst frames, or
  a Markup-annotated copy that must not be deleted.
- **Videos** match on dimensions, duration within 0.05 s, and the same capture time
  (±2 s) or identical size.
- **Kept copy:** favourite > edited > highest resolution > largest file > oldest.
  Groups are ordered by the space they'd free.
- **Measured:** the whole pass takes ~16 s with prints cached. On the test library
  it found ~2,800 groups (~156 GB), almost all of it videos imported twice.

## Video compression

- **Constant quality, not bitrate.** A fixed bits-per-pixel budget gave 39 dB PSNR on
  one 4K clip and 27 dB on another. VideoToolbox constant quality adapts to content:
  Low 0.45 · Medium 0.55 · High 0.65.
- **Early abort.** While encoding, the final size is projected from the bytes written;
  if the saving would be under 40% the job stops and the video is marked "Already
  efficient". Many modern iPhone HEVC files fall here.
- **Preserved:** rotation, every audio track (including the spatial-audio track newer
  iPhones record), HDR transfer function (HLG/PQ, 10-bit), and the creation date.
  **Not preserved:** iPhone timed-metadata tracks (Apple's own exports drop them too)
  and Dolby Vision RPU data (the HLG base layer is kept).
- **Skipped:** slo-mo, time-lapse, cinematic, edited videos, and clips under 3 s.
- **Replace is atomic.** One `performChanges` creates every compressed copy (date,
  location, favourite, user albums, original filename) and deletes the originals:
  one macOS prompt, and if you decline nothing changes at all.
- **Cancellation.** A cancelled `AVAssetWriter` stops asking for data, so each sample
  pump is released by a latch on cancel; otherwise Stop (or the early abort) hangs.
- **Measured:** 4K HDR, 2 min: 523 MB → 99 MB (81% smaller) at 42 dB, 4× realtime.

## Known limitations

- The first scan of a very large library takes a while (minutes per 10k photos).
- The duplicates keep rule doesn't yet consider album membership: deleting a copy
  removes it from any album only that copy was in.
- Groups appear after the first scan finishes (not streamed during it).
- Not sandboxed and not notarised: you build and sign it yourself (see README).

## Ideas

- "Space reclaimed" running total and history.
- Settings: time window, score weights, grid density, confirm-on-quit.
- Prefer the duplicate copy that's in more albums.
