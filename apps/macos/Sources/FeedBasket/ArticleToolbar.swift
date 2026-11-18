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
    static let controlHeight: CGFloat = 28
    static let outlineHeight: CGFloat = 20.9
    static let modeIconSize: CGFloat = 12
    static let selectionInset: CGFloat = 3
}

struct ArticleToolbarLabel: View {
    let title: String
    let icon: String
    let display: ReaderToolbarDisplay
    var isMode = false

    var body: some View {
        HStack(spacing: 4) {
            if display != .names {
                if isMode {
                    Image(systemName: icon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: ArticleToolbarMetrics.modeIconSize, height: ArticleToolbarMetrics.modeIconSize)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .medium))
                        .accessibilityHidden(true)
                }
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
    @Environment(\.isEnabled) private var isEnabled
    var isMode = false
    var selected = false

    private var labelOpacity: Double {
        guard isMode else { return 1 }
        if selected { return isEnabled ? 1 : 0.8 }
        return isEnabled ? 0.64 : 0.25
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(labelOpacity)
            .background {
                if isMode && (selected || (isEnabled && configuration.isPressed)) {
                    RoundedRectangle(cornerRadius: BasketTokens.radius - 1)
                        .fill(selected ? style.accent.opacity(0.15) : style.color(BasketTokens.subtle))
                        .frame(height: ArticleToolbarMetrics.outlineHeight - 2 * ArticleToolbarMetrics.selectionInset)
                        .padding(.horizontal, ArticleToolbarMetrics.selectionInset)
                } else if !isMode && configuration.isPressed {
                    RoundedRectangle(cornerRadius: BasketTokens.radius)
                        .fill(style.color(BasketTokens.subtle))
                }
            }
    }
}
