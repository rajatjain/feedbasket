import AppKit
import SwiftUI

enum ArticleAction: CaseIterable {
    case archive, star, dislike

    var key: KeyEquivalent {
        switch self {
        case .archive: "a"
        case .star: .upArrow
        case .dislike: .downArrow
        }
    }

    var shortcut: String {
        switch self {
        case .archive: "⌘⇧A"
        case .star: "⌘⇧↑"
        case .dislike: "⌘⇧↓"
        }
    }

    func title(for article: Article? = nil) -> String {
        switch self {
        case .archive: "Archive"
        case .star: article?.isStarred == true ? "Unstar" : "Star"
        case .dislike: "Dislike"
        }
    }

    func allows(_ article: Article) -> Bool {
        self == .archive ? article.location == "inbox" : article.location != "trash"
    }
}

struct SelectedArticleActions {
    let article: Article
    let perform: (ArticleAction) -> Void
}

private struct SelectedArticleActionsKey: FocusedValueKey {
    typealias Value = SelectedArticleActions
}

extension FocusedValues {
    var selectedArticleActions: SelectedArticleActions? {
        get { self[SelectedArticleActionsKey.self] }
        set { self[SelectedArticleActionsKey.self] = newValue }
    }
}

struct ArticleCommands: Commands {
    @FocusedValue(\.selectedArticleActions) private var selection
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Article") {
            ForEach(ArticleAction.allCases, id: \.self) { action in
                Button(action.title(for: selection?.article)) {
                    guard let selection else { return }
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView, editor.isEditable { return }
                    selection.perform(action)
                }
                .keyboardShortcut(action.key, modifiers: [.command, .shift])
                .disabled(selection.map { !action.allows($0.article) } ?? true)
            }
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: "keyboard-shortcuts") }
        }
    }
}

struct TrashUndoShortcut: NSViewRepresentable {
    let undo: () -> Void

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.undo = undo
    }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ShortcutView: NSView {
        var undo: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            // Leave text editing and other windows on the standard macOS undo path.
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.attachedSheet == nil, NSApp.modalWindow == nil,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "z" else { return event }
                if let editor = window.firstResponder as? NSTextView, editor.isEditable { return event }
                guard let undo = self.undo else { return event }
                undo()
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

struct ArticleShortcutList: View {
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: BasketTokens.spacing) {
            ForEach(ArticleAction.allCases, id: \.self) { action in
                GridRow {
                    Text(action == .star ? "Star or unstar" : action.title())
                    Text(action.shortcut).monospaced().gridColumnAlignment(.trailing)
                }
            }
            GridRow {
                Text("Undo move to Trash")
                Text("⌘Z").monospaced().gridColumnAlignment(.trailing)
            }
        }
        .padding(BasketTokens.spacing * 3)
    }
}
