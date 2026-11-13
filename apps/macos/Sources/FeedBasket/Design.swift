import AppKit
import SwiftUI

struct PublisherIdentity {
    let title: String
    let url: String

    var domain: String { URL(string: url)?.host() ?? url }
    var monogram: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((name.isEmpty ? domain : name).prefix(1)).uppercased()
    }
}

struct PublisherCardStyle {
    static let preview = Self(badgeSize: 38, badgeFont: 20, gap: 11, horizontalInset: 13, verticalInset: 13)
    static let compact = Self(badgeSize: 26, badgeFont: 14, gap: 8, horizontalInset: 8, verticalInset: 5)

    let badgeSize: Int
    let badgeFont: Int
    let gap: Int
    let horizontalInset: Int
    let verticalInset: Int

    var badgeRadius: Int { badgeSize / 4 }
    var cornerRadius: Int { badgeRadius + 1 }

    static let background = BasketTokens.subtle
    static let badgeText = BasketTokens.onAccent
    static let secondaryText = BasketTokens.muted
    static let badgeWeight = 600

    static func badgeBackground(_ style: BasketStyle) -> (UInt32, UInt32) {
        style.accentPair
    }
}

// Use the property wrapper with SDKs that also expose a State macro.
typealias BasketState<Value> = SwiftUI.State<Value>

enum BasketTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var label: String { self == .system ? "Follow macOS" : rawValue.capitalized }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct BasketStyle {
    let scheme: ColorScheme
    let accentName: String

    func hex(_ pair: (UInt32, UInt32)) -> UInt32 { scheme == .dark ? pair.1 : pair.0 }
    func color(_ pair: (UInt32, UInt32)) -> Color {
        let value = hex(pair)
        return Color(red: Double(value >> 16) / 255, green: Double((value >> 8) & 255) / 255,
                     blue: Double(value & 255) / 255)
    }
    func css(_ pair: (UInt32, UInt32)) -> String { String(format: "#%06x", hex(pair)) }
    var accentPair: (UInt32, UInt32) { BasketTokens.accents[accentName] ?? BasketTokens.accents["green"]! }
    var accent: Color { color(accentPair) }
}

struct BasketAppearance: ViewModifier {
    @AppStorage("theme") private var theme = BasketTheme.system
    @AppStorage("accent") private var accent = "green"

    func body(content: Content) -> some View {
        BasketSurface(accent: accent) { content }
            .preferredColorScheme(theme.scheme)
    }
}

private struct BasketSurface<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    let accent: String
    @ViewBuilder let content: Content

    var body: some View {
        let style = BasketStyle(scheme: scheme, accentName: accent)
        content
            .font(.system(size: BasketTokens.bodySize))
            .foregroundStyle(style.color(BasketTokens.text))
            .background(style.color(BasketTokens.surface))
            .tint(style.accent)
            .environment(\.basketStyle, style)
            .onChange(of: scheme, initial: true) { _, scheme in
                NSApplication.shared.applicationIconImage = scheme == .dark
                    ? FeedBasketArtwork.darkDockIcon : nil
            }
    }
}

private struct BasketStyleKey: EnvironmentKey {
    static let defaultValue = BasketStyle(scheme: .light, accentName: "green")
}

extension EnvironmentValues {
    var basketStyle: BasketStyle {
        get { self[BasketStyleKey.self] }
        set { self[BasketStyleKey.self] = newValue }
    }
}

struct BasketButton: ButtonStyle {
    @Environment(\.basketStyle) private var style
    @Environment(\.isEnabled) private var enabled
    var primary = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: BasketTokens.bodySize, weight: primary ? .semibold : .regular))
            .padding(.horizontal, BasketTokens.spacing)
            .padding(.vertical, 5)
            .foregroundStyle(primary ? style.color(BasketTokens.onAccent) : style.color(BasketTokens.text))
            .background(primary ? style.accent : style.color(BasketTokens.surface))
            .clipShape(.rect(cornerRadius: BasketTokens.radius))
            .overlay { RoundedRectangle(cornerRadius: BasketTokens.radius).strokeBorder(
                primary ? .clear : style.color(BasketTokens.line)
            ) }
            .opacity(enabled ? (configuration.isPressed ? 0.78 : 1) : 0.45)
    }
}

struct BasketStatus: View {
    let online: Bool

    var title: String { online ? "Server online" : "Server offline" }

    private var color: Color {
        online ? Color(red: 0.10, green: 0.52, blue: 0.27)
               : Color(red: 0.81, green: 0.24, blue: 0.24)
    }

    var dot: some View {
        Circle().fill(color).frame(width: 9, height: 9)
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            dot
        }
        .font(.system(size: BasketTokens.labelSize))
    }
}

@MainActor
private enum FeedBasketArtwork {
    static let lightIcon = loadIcon("feedbasket-light")
    static let darkIcon = loadIcon("feedbasket-dark")
    static let darkDockIcon = loadIcon("feedbasket-dock-dark")

    private static func loadIcon(_ name: String) -> NSImage? {
        Bundle.main.url(forResource: name, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }
}

struct FeedBasketWordmark: View {
    @Environment(\.basketStyle) private var style

    var body: some View {
        HStack(spacing: BasketTokens.spacing) {
            if let icon = style.scheme == .dark ? FeedBasketArtwork.darkIcon : FeedBasketArtwork.lightIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 25, height: 25)
                    .accessibilityHidden(true)
            }
            Text("\(Text("Feed").foregroundStyle(style.accent))\(Text("Basket").foregroundStyle(style.color(BasketTokens.text)))")
                .font(.system(size: 22, weight: .black))
                .tracking(-0.8)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

struct BasketEmpty: View {
    let title: String
    let icon: String
    var body: some View {
        ContentUnavailableView(title, systemImage: icon)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TagLabel: View {
    @Environment(\.basketStyle) private var style
    let tag: String
    var body: some View {
        Text(tag).font(.system(size: BasketTokens.labelSize)).padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(style.accent).background(style.color(BasketTokens.subtle))
            .clipShape(.rect(cornerRadius: BasketTokens.radius))
    }
}
