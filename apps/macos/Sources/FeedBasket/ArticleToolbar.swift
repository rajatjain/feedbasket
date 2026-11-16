import SwiftUI

enum ReaderToolbarDisplay: String, CaseIterable, Identifiable {
    static let key = "readerToolbarDisplay"

    case icons, names, both

    var id: Self { self }

    var title: String {
        switch self {
        case .icons: "Icons Only"
        case .names: "Names Only"
        case .both: "Icons and Names"
        }
    }
}

enum ArticleToolbarMetrics {
    static let controlHeight: CGFloat = 30
    static let outlineHeight: CGFloat = 20.9
}

struct ArticleToolbarLabel: View {
    let title: String
    let icon: String
    let display: ReaderToolbarDisplay
    var isMode = false

    var body: some View {
        HStack(spacing: 4) {
            if display != .names {
                Image(systemName: icon)
                    .font(.system(size: isMode ? 17 : 15, weight: .medium))
                    .accessibilityHidden(true)
            }
            if display != .icons {
                Text(title).font(.system(size: 11))
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, display == .icons ? 0 : 6)
        .frame(minWidth: isMode ? 33 : 30)
        .frame(height: ArticleToolbarMetrics.controlHeight)
        .contentShape(Rectangle())
    }
}

struct ArticleToolbarButtonStyle: ButtonStyle {
    @Environment(\.basketStyle) private var style
    var isMode = false
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if isMode && (selected || configuration.isPressed) {
                    RoundedRectangle(cornerRadius: BasketTokens.radius - 1)
                        .fill(selected ? style.accent.opacity(0.15) : style.color(BasketTokens.subtle))
                        .frame(height: ArticleToolbarMetrics.outlineHeight - 4)
                        .padding(.horizontal, 2)
                } else if configuration.isPressed {
                    RoundedRectangle(cornerRadius: BasketTokens.radius)
                        .fill(style.color(BasketTokens.subtle))
                }
            }
    }
}
