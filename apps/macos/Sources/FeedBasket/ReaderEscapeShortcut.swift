import AppKit
import PDFKit
import SwiftUI
import WebKit

/// WebKit and PDFKit can consume Escape before it reaches SwiftUI's onExitCommand.
/// Route it from document content only, leaving editors, popovers, and sheets on
/// their normal cancellation paths.
struct ReaderEscapeShortcut: NSViewRepresentable {
    let escape: () -> Void

    func makeNSView(context: Context) -> ShortcutView { ShortcutView() }

    func updateNSView(_ view: ShortcutView, context: Context) {
        view.escape = escape
    }

    static func dismantleNSView(_ view: ShortcutView, coordinator: ()) {
        view.removeMonitor()
    }

    final class ShortcutView: NSView {
        var escape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeMonitor()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      window.isKeyWindow, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      event.keyCode == 53, !event.isARepeat,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                      let responder = window.firstResponder as? NSView else { return event }
                if let editor = responder as? NSTextView, editor.isEditable { return event }
                var ancestor: NSView? = responder
                while let view = ancestor {
                    if view is WKWebView || view is PDFView {
                        guard let escape = self.escape else { return event }
                        escape()
                        return nil
                    }
                    ancestor = view.superview
                }
                return event
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
