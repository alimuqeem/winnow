import Photos
import SwiftUI
import WinnowCore

/// Loads a Photos image for `id` at roughly `side` points; upgrades from the
/// fast degraded image to the final one as PhotoKit delivers them.
struct ThumbnailView: View {
    @Environment(AppModel.self) private var app
    let id: AssetID
    var side: CGFloat = 160
    var highQuality = false
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

    var body: some View {
        // The image is an overlay so it never drives the layout size; the
        // cell's frame comes from the parent and the overflow is clipped.
        Rectangle()
            .fill(contentMode == .fill ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
            .overlay {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                }
            }
            .clipped()
        .task(id: TaskKey(id: id, side: side)) {
            image = nil
            let library = app.library
            var request: PHImageRequestID?
            await withTaskCancellationHandler {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    var resumed = false
                    request = library.requestImage(id, side: side, highQuality: highQuality) { img in
                        image = img
                        if !resumed { resumed = true; done.resume() }
                    }
                    if request == nil { resumed = true; done.resume() }
                }
            } onCancel: {
                if let request { Task { @MainActor in library.cancel(request) } }
            }
        }
    }

    private struct TaskKey: Hashable { let id: AssetID; let side: CGFloat }
}
