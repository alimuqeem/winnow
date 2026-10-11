import SwiftUI
import WinnowCore

/// Mirrors Photos: Library (All Photos, To Delete), Smart Albums, Albums + folders (PLAN.md Phase 1).
struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selection) {
            Section("Library") {
                if let all = app.library.collections.first(where: { $0.kind == .allPhotos }) {
                    row(all, icon: "photo.on.rectangle")
                }
                Label("Duplicates", systemImage: "plus.square.on.square")
                    .tag(SidebarItem.duplicates)
                    .help("Exact copies anywhere in the library, photos and videos")
                Label {
                    HStack {
                        Text("To Delete")
                        Spacer()
                        if app.bin.count > 0 { count(app.bin.count).foregroundStyle(.red) }
                    }
                } icon: { Image(systemName: "trash") }
                .tag(SidebarItem.toDelete)
            }

            Section("Tools") {
                Label("Compress Videos", systemImage: "film")
                    .tag(SidebarItem.videos)
            }

            ForEach(app.library.collections.filter { $0.kind == .folder }) { section in
                Section(section.title) {
                    OutlineGroup(section.children, children: \.childrenOrNil) { collection in
                        row(collection, icon: icon(for: collection))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if !app.library.isAuthorized {
                ContentUnavailableView("No Photos Access", systemImage: "lock",
                                       description: Text(app.library.statusLine))
            }
        }
    }

    @ViewBuilder
    private func row(_ collection: LibraryCollection, icon: String) -> some View {
        let label = Label {
            HStack {
                Text(collection.title).lineLimit(1)
                Spacer()
                if collection.kind != .folder { count(collection.count) }
            }
        } icon: { Image(systemName: icon) }
        if collection.kind == .folder {
            label.selectionDisabled()
        } else {
            label.tag(SidebarItem.collection(collection.id))
        }
    }

    private func count(_ n: Int) -> some View {
        Text(n.formatted()).font(.caption).foregroundStyle(.secondary).monospacedDigit()
    }

    private func icon(for c: LibraryCollection) -> String {
        switch c.kind {
        case .allPhotos: "photo.on.rectangle"
        case .smartAlbum:
            switch c.title {
            case "Favorites", "Favourites": "heart"
            case "Screenshots": "camera.viewfinder"
            case "Selfies": "person.crop.square"
            case "Panoramas": "pano"
            case "RAW": "r.square"
            case "Bursts": "square.stack.3d.down.right"
            case "Live Photos": "livephoto"
            case "Portrait": "cube"
            default: "gearshape"
            }
        case .album: "rectangle.stack"
        case .folder: "folder"
        }
    }
}

extension LibraryCollection {
    var childrenOrNil: [LibraryCollection]? { kind == .folder ? children : nil }
}
