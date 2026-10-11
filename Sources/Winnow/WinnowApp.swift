import AppKit
import SwiftUI
import WinnowCore

@main
struct WinnowApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 1000, minHeight: 640)
                .task { await delegate.model.start() }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { delegate.model.activeReview?.edit { $0.undo() } }
                    .keyboardShortcut("z")
                Button("Redo") { delegate.model.activeReview?.edit { $0.redo() } }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch app.selection {
            case .toDelete:
                TrashView()
            case .videos:
                VideosView()
            case .duplicates:
                CollectionView(collection: app.duplicatesCollection).id(AppModel.duplicatesID)
            case .collection(let id):
                if let collection = app.collection(withID: id) {
                    CollectionView(collection: collection).id(id)
                } else {
                    placeholder
                }
            case nil:
                placeholder
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Text("Winnow").font(.largeTitle.bold())
            Text(app.library.statusLine).foregroundStyle(.secondary)
        }
    }
}

/// Owns the model so quit can be intercepted while deletions are pending (PLAN.md Phase 5).
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let args = SelfTest.arguments() {
            Task { @MainActor in await SelfTest.run(model, args: args) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.bin.isEmpty, SelfTest.arguments() == nil else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Move \(model.bin.count) photos to Recently Deleted?"
        alert.informativeText = "They'll stay in Photos › Recently Deleted for 30 days. Choose Keep for Later to quit and decide next time."
        alert.addButton(withTitle: "Move to Recently Deleted")
        alert.addButton(withTitle: "Keep for Later")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                do {
                    try await model.commitBin()
                    await model.flush()
                    sender.reply(toApplicationShouldTerminate: true)
                } catch {
                    let failed = NSAlert()
                    failed.messageText = "Nothing was deleted"
                    failed.informativeText = error.localizedDescription
                    failed.runModal()
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        case .alertSecondButtonReturn:
            Task { @MainActor in
                await model.flush()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        default:
            return .terminateCancel
        }
    }
}
