import SwiftUI

enum BasketInterfaceStyle: String, CaseIterable, Identifiable {
    case classic, liquidGlass

    var id: Self { self }
    var label: String { self == .classic ? "Classic" : "Liquid Glass" }

    static var supportsLiquidGlass: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    func usesGlass(reduceTransparency: Bool, increasedContrast: Bool) -> Bool {
        self == .liquidGlass && Self.supportsLiquidGlass && !reduceTransparency && !increasedContrast
    }
}

private struct BasketInterfaceStyleKey: EnvironmentKey {
    static let defaultValue = BasketInterfaceStyle.classic
}

extension EnvironmentValues {
    var basketInterfaceStyle: BasketInterfaceStyle {
        get { self[BasketInterfaceStyleKey.self] }
        set { self[BasketInterfaceStyleKey.self] = newValue }
    }
}

/// Navigation uses sidebar vibrancy; control surfaces use native Liquid Glass.
/// Keep article text, PDF pages, and library rows on their existing solid surfaces.
struct BasketChrome: ViewModifier {
    enum Role { case sidebar, toolbar, floating }

    @Environment(\.basketStyle) private var style
    @Environment(\.basketInterfaceStyle) private var interfaceStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let role: Role
    let fallback: Color
    var radius: CGFloat = 0

    func body(content: Content) -> some View {
        content.background {
            surface.allowsHitTesting(false)
        }
    }

    @ViewBuilder private var surface: some View {
        if #available(macOS 26, *),
           interfaceStyle.usesGlass(reduceTransparency: reduceTransparency, increasedContrast: contrast == .increased) {
            if role == .sidebar {
                Rectangle().fill(.regularMaterial)
                    .overlay(style.accent.opacity(0.04))
            } else {
                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: radius))
            }
        } else {
            RoundedRectangle(cornerRadius: radius).fill(fallback)
        }
    }
}

extension View {
    func basketChrome(_ role: BasketChrome.Role, fallback: Color = .clear, radius: CGFloat = 0) -> some View {
        modifier(BasketChrome(role: role, fallback: fallback, radius: radius))
    }
}
