import SwiftUI

struct BasketAppearanceSettings: View {
    @AppStorage("theme") private var theme = BasketTheme.system
    @AppStorage("accent") private var accent = BasketTokens.defaultPalette
    @AppStorage("interfaceStyle") private var interfaceStyle = BasketInterfaceStyle.classic
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $theme) {
                    ForEach(BasketTheme.allCases) { Text($0.label).tag($0) }
                }
                Picker("Palette", selection: Binding(
                    get: { BasketStyle.palette(for: accent).id },
                    set: { accent = $0 }
                )) {
                    ForEach(BasketTokens.palettes) { Text($0.label).tag($0.id) }
                }
            }
            Section {
                Picker("Interface style", selection: $interfaceStyle) {
                    ForEach(BasketInterfaceStyle.allCases) { value in
                        Text(value.label).tag(value)
                            .disabled(value == .liquidGlass && !BasketInterfaceStyle.supportsLiquidGlass)
                    }
                }
                .pickerStyle(.segmented)
                Text(explanation).font(.caption).foregroundStyle(.secondary)
            }
            Section("Preview") {
                BasketAppearancePreview()
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(interfaceStyle.label) interface with your selected theme and palette")
            }
        }
        .formStyle(.grouped)
    }

    private var explanation: String {
        if !BasketInterfaceStyle.supportsLiquidGlass {
            return "Liquid Glass requires macOS 26 or later."
        }
        if interfaceStyle == .liquidGlass && (reduceTransparency || contrast == .increased) {
            return "Solid surfaces are used while Reduce Transparency or Increase Contrast is enabled."
        }
        return "Liquid Glass adds translucent navigation and controls. Your palette and reading background stay the same."
    }
}

/// Uses the app's wordmark, tags, typography, and shared material in a small library preview.
private struct BasketAppearancePreview: View {
    @Environment(\.basketStyle) private var style

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                FeedBasketWordmark(compact: true)
                Label("All articles", systemImage: "bookmark")
                Label("PDFs", systemImage: "doc.richtext")
                Label("Starred", systemImage: "star")
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 170)
            .frame(maxHeight: .infinity)
            .basketChrome(.sidebar, fallback: style.color(style.palette.sidebar))
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: "textformat")
                    Spacer()
                    Image(systemName: "star")
                    Image(systemName: "archivebox")
                    Image(systemName: "tag")
                }
                .padding(.horizontal, 12).frame(height: 32)
                .basketChrome(.toolbar, fallback: style.color(style.readingSurface))
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your reading space").font(.system(size: 18, weight: .bold, design: .serif))
                    Text("Articles, feeds, and PDFs in one place.")
                        .font(.system(size: 12, design: .serif))
                    TagLabel(tag: "reading")
                }.padding(12)
                Spacer(minLength: 0)
            }
            .background(style.color(style.readingSurface))
        }
        .frame(height: 155)
        .clipShape(.rect(cornerRadius: BasketTokens.radius))
        .overlay {
            RoundedRectangle(cornerRadius: BasketTokens.radius).strokeBorder(style.color(BasketTokens.line))
        }
    }
}
