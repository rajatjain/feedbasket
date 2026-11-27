import SwiftUI

struct PDFToolbarButton: View {
    let title: String
    let icon: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly) }
            .buttonStyle(ReaderToolbarButtonStyle(active: active))
            .help(title)
    }
}

struct PDFPageControl: View {
    @Environment(\.basketStyle) private var style
    let page: Int
    let count: Int
    let go: (Int) -> Void

    @BasketState private var entry = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 2) {
            PDFToolbarButton(title: "Previous page", icon: "chevron.left") { navigate(to: page - 1) }
                .disabled(page <= 1)
            TextField("Page number", text: $entry)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(.system(size: BasketTokens.labelSize, weight: .semibold))
                .monospacedDigit()
                .frame(width: max(22, CGFloat(String(count).count) * 8 + 3), height: 22)
                .background(editing ? style.color(style.readingSurface) : .clear, in: .rect(cornerRadius: 4))
                .focused($editing)
                .help("Enter a page number from 1 to \(count)")
                .onSubmit(commit)
                .onExitCommand {
                    entry = String(page)
                    editing = false
                }
            Text("/ \(count)")
                .font(.system(size: BasketTokens.labelSize))
                .monospacedDigit()
                .foregroundStyle(style.color(BasketTokens.muted))
                .accessibilityLabel("of \(count) pages")
            PDFToolbarButton(title: "Next page", icon: "chevron.right") { navigate(to: page + 1) }
                .disabled(page >= count)
        }
        .fixedSize()
        .background(style.color(BasketTokens.subtle), in: .rect(cornerRadius: BasketTokens.radius))
        .onChange(of: page, initial: true) { if !editing { entry = String(page) } }
        .onChange(of: editing) { if !editing { entry = String(page) } }
    }

    private func commit() {
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = Int(value), target >= 1, target <= count else {
            NSSound.beep()
            entry = String(page)
            return
        }
        navigate(to: target)
    }

    private func navigate(to target: Int) {
        editing = false
        entry = String(target)
        go(target)
    }
}

struct PDFToolbarPanel: ViewModifier {
    @Environment(\.basketStyle) private var style

    func body(content: Content) -> some View {
        content
            .basketChrome(.floating, fallback: style.color(style.palette.surface), radius: BasketTokens.radius)
            .overlay {
                RoundedRectangle(cornerRadius: BasketTokens.radius).strokeBorder(style.color(BasketTokens.line))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.14), radius: 6, y: 2)
    }
}

struct PDFFindPanel: View {
    @Environment(\.basketStyle) private var style
    @Binding var query: String
    let focusRequest: Int
    let status: String
    let canNavigate: Bool
    let submit: () -> Void
    let step: (Int) -> Void
    let close: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    .foregroundStyle(style.color(BasketTokens.muted))
                TextField("Find in PDF", text: $query)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(submit)
                if !status.isEmpty {
                    Text(status)
                        .font(.system(size: BasketTokens.labelSize))
                        .monospacedDigit()
                        .foregroundStyle(style.color(BasketTokens.muted))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 8)
            .frame(width: 224, height: 29)
            .background(style.color(BasketTokens.subtle), in: .rect(cornerRadius: BasketTokens.radius))
            .overlay {
                RoundedRectangle(cornerRadius: BasketTokens.radius)
                    .strokeBorder(focused ? style.accent.opacity(0.55) : style.color(BasketTokens.line))
                    .allowsHitTesting(false)
            }
            PDFToolbarButton(title: "Previous match", icon: "chevron.up") { step(-1) }
                .disabled(!canNavigate)
            PDFToolbarButton(title: "Next match", icon: "chevron.down") { step(1) }
                .disabled(!canNavigate)
            Divider().frame(height: 15)
            PDFToolbarButton(title: "Close search", icon: "xmark", action: close)
        }
        .padding(5)
        .modifier(PDFToolbarPanel())
        .fixedSize()
        .task(id: focusRequest) {
            await Task.yield()
            if !Task.isCancelled { focused = true }
        }
        .onExitCommand(perform: close)
    }
}

struct PDFSelectionToolbar: View {
    let mark: (Highlight.Mark) -> Void
    private static let marks: [Highlight.Mark] = [.highlight, .underline]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Self.marks, id: \.self) { style in
                if style == .underline { Divider().frame(height: 16) }
                Button { mark(style) } label: {
                    Label(style.label, systemImage: style.icon)
                        .font(.system(size: BasketTokens.labelSize, weight: .semibold))
                        .padding(.horizontal, 9)
                        .frame(height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .modifier(PDFToolbarPanel())
        .fixedSize()
    }
}

struct PDFPageOverlays: View {
    let selection: CGRect?
    let matches: [CGRect]
    let mark: (Highlight.Mark) -> Void
    @BasketState private var toolbarSize = CGSize(width: 180, height: 32)

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(matches.enumerated()), id: \.offset) { _, rect in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue.opacity(0.10))
                    .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color.blue.opacity(0.65)) }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            if let selection, geometry.size.width >= toolbarSize.width + 16,
               geometry.size.height >= toolbarSize.height + 16 {
                let halfWidth = toolbarSize.width / 2
                let halfHeight = toolbarSize.height / 2
                let above = selection.minY - halfHeight - 8
                let below = selection.maxY + halfHeight + 8
                PDFSelectionToolbar(mark: mark)
                    .onGeometryChange(for: CGSize.self, of: \.size) { toolbarSize = $0 }
                    .position(x: min(max(selection.midX, halfWidth + 8), geometry.size.width - halfWidth - 8),
                              y: min(above >= halfHeight + 8 ? above : below, geometry.size.height - halfHeight - 8))
            }
        }
        .clipped()
    }
}
