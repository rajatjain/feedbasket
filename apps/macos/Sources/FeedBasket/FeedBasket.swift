import AppKit
import SwiftUI

@main
struct FeedBasket: App {
    @BasketState private var store: BasketStore = BasketStore()
    @BasketState private var update = InstalledAppUpdate()

    var body: some Scene {
        WindowGroup("FeedBasket") {
            LibraryWindow()
                .environment(store)
                .environment(update)
                .modifier(BasketAppearance())
                .frame(minWidth: 820, minHeight: 480)
                .task(id: store.sessionRevision) { [revision = store.sessionRevision] in
                    await store.watchSavedUpdates(revision: revision)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    update.check()
                    Task { await store.refresh() }
                }
                .task { await update.watch() }
                .task {
                    while !Task.isCancelled {
                        await store.refresh()
                        try? await Task.sleep(for: .seconds(15))
                    }
                }
        }
        .defaultSize(width: 1120, height: 700)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { ArticleCommands() }

        Window("Keyboard Shortcuts", id: "keyboard-shortcuts") {
            ArticleShortcutList().modifier(BasketAppearance())
        }
        .windowResizability(.contentSize)

        Settings {
            BasketSettings().environment(store).modifier(BasketAppearance())
        }
    }
}
