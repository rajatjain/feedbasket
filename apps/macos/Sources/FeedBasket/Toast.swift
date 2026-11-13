import SwiftUI

struct BasketToast: Identifiable {
    enum Location: Hashable { case reader, articleList, settings }
    enum Action { case undoArticleChange }

    let id = UUID()
    let text: String
    let icon: String
    var action: Action? = nil
}

struct BasketToastOverlay: ViewModifier {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let location: BasketToast.Location

    func body(content: Content) -> some View {
        let toast = store.toasts[location]
        content.overlay(alignment: .bottom) {
            if let toast {
                HStack(spacing: 12) {
                    Label(toast.text, systemImage: toast.icon)
                        .fixedSize(horizontal: false, vertical: true)
                    if toast.action == .undoArticleChange && store.canUndoArticleChange {
                        Button("Undo", action: store.undoArticleChange)
                            .buttonStyle(BasketButton())
                            .help("Undo article change (⌘Z)")
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(style.color(BasketTokens.surface), in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(style.color(BasketTokens.line)) }
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
                .padding(.horizontal, 16).padding(.bottom, 18)
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: toast != nil)
    }
}
