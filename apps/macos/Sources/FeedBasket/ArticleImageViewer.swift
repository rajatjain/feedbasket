import AppKit
import SwiftUI

struct ArticleImage {
    static let handler = "articleImage"
    let source: URL
    let original: URL
    let caption: String

    init?(_ fields: [String: String]) {
        guard let source = Self.webURL(fields["source"]) else { return nil }
        self.source = source
        self.original = Self.webURL(fields["original"]) ?? source
        self.caption = String((fields["caption"] ?? "").prefix(500))
    }

    private static func webURL(_ value: String?) -> URL? {
        guard let value, let parts = URLComponents(string: value),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else { return nil }
        return parts.url
    }

    static let script = #"""
        (() => {
            const article = document.querySelector('article');
            if (!article) return;
            const webURL = value => /^https?:\/\//i.test(value || '');
            const images = Array.from(article.querySelectorAll('img')).filter(image => webURL(image.src));
            const show = image => {
                const source = image.currentSrc || image.src;
                if (!webURL(source)) return false;
                const link = image.closest('a')?.href;
                const original = webURL(link) && /\.(avif|gif|jpe?g|png|svg|webp|tiff?|bmp)(?:[?#]|$)/i.test(link)
                    ? link : source;
                const caption = image.closest('figure')?.querySelector('figcaption')?.textContent.trim()
                    || image.alt.trim();
                window.webkit.messageHandlers.articleImage.postMessage({source, original, caption});
                return true;
            };
            for (const image of images) {
                image.tabIndex = 0;
                image.setAttribute('role', 'button');
                image.setAttribute('aria-label', image.alt ? 'Expand image: ' + image.alt : 'Expand image');
            }
            article.addEventListener('click', event => {
                if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
                if (event.target instanceof HTMLImageElement && show(event.target)) event.preventDefault();
            });
            article.addEventListener('keydown', event => {
                if ((event.key === 'Enter' || event.key === ' ') && event.target instanceof HTMLImageElement
                    && show(event.target)) event.preventDefault();
            });
        })();
        """#
}

struct ArticleImageReaderBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct ArticleImageViewer: View {
    @Environment(\.basketStyle) private var style
    @FocusState private var closeFocused: Bool
    @BasketState private var loaded: NSImage?
    @BasketState private var failed = false
    @BasketState private var zoom = ImageZoomRequest(command: .fit)
    @BasketState private var percent = 100
    let image: ArticleImage
    let expanded: Bool
    let canExpand: Bool
    let resize: () -> Void
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(expanded ? 0.65 : 0.35)
                .onTapGesture(perform: close)
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                toolbar
                Divider()
                Group {
                    if let loaded {
                        ArticleImageCanvas(image: loaded, description: image.caption, zoom: zoom,
                                           source: image.original, reportScale: { percent = Int(($0 * 100).rounded()) })
                    } else if failed {
                        VStack(spacing: BasketTokens.spacing) {
                            Text("Couldn’t load the image")
                            Button("Open Image in Browser") { NSWorkspace.shared.open(image.original) }
                                .buttonStyle(BasketButton())
                        }
                    } else {
                        ProgressView("Loading image…").controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(style.color(style.readingSurface))
                if !image.caption.isEmpty {
                    Divider()
                    Text(image.caption)
                        .font(.system(size: BasketTokens.labelSize))
                        .foregroundStyle(style.color(BasketTokens.muted))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity)
                        .padding(BasketTokens.spacing)
                }
            }
            .contentShape(Rectangle())
            .clipShape(.rect(cornerRadius: BasketTokens.radius))
            .modifier(PDFToolbarPanel())
            .padding(BasketTokens.spacing * 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Image viewer")
        .onExitCommand(perform: close)
        .task {
            closeFocused = true
            await load()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 3) {
            Group {
                Button("Fit") { zoom = .init(command: .fit) }
                    .buttonStyle(BasketButton())
                    .help("Fit image")
                Button("100%") { zoom = .init(command: .actualSize) }
                    .buttonStyle(BasketButton())
                    .help("Actual size")
                Divider().frame(height: 16).padding(.horizontal, 3)
                PDFToolbarButton(title: "Zoom out", icon: "minus") { zoom = .init(command: .step(0.8)) }
                Text("\(percent)%")
                    .font(.system(size: BasketTokens.labelSize))
                    .monospacedDigit()
                    .frame(minWidth: 42)
                    .accessibilityLabel("Zoom \(percent) percent")
                PDFToolbarButton(title: "Zoom in", icon: "plus") { zoom = .init(command: .step(1.25)) }
            }
            .disabled(loaded == nil)
            Spacer(minLength: 2)
            if canExpand {
                PDFToolbarButton(title: expanded ? "Return to reading pane" : "Expand to window",
                                 icon: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                 action: resize)
            }
            PDFToolbarButton(title: "Close image", icon: "xmark", action: close)
                .focusable()
                .focused($closeFocused)
                .keyboardShortcut(.cancelAction)
        }
        .padding(5)
    }

    private func load() async {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let urls = image.original == image.source ? [image.source] : [image.original, image.source]
        for url in urls {
            do {
                let (data, response) = try await session.data(from: url)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                      let decoded = NSImage(data: data), decoded.isValid else { continue }
                loaded = decoded
                return
            } catch {
                if Task.isCancelled { return }
            }
        }
        failed = true
    }
}

private struct ImageZoomRequest {
    enum Command {
        case fit, actualSize, step(CGFloat)
    }

    let id = UUID()
    let command: Command
}

private struct ArticleImageCanvas: NSViewRepresentable {
    let image: NSImage
    let description: String
    let zoom: ImageZoomRequest
    let source: URL
    let reportScale: (CGFloat) -> Void

    func makeNSView(context: Context) -> ImageScrollView {
        ImageScrollView(image: image, description: description, source: source)
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        view.reportScale = reportScale
        view.apply(zoom)
    }
}

private final class ImageScrollView: NSScrollView {
    private var fitsWindow = true
    private var lastRequest: UUID?
    private var lastScale: CGFloat?
    var reportScale: ((CGFloat) -> Void)?

    init(image: NSImage, description: String, source: URL) {
        super.init(frame: .zero)
        contentView = CenteredImageClipView()
        drawsBackground = false
        contentView.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        scrollerStyle = .overlay
        autohidesScrollers = true
        allowsMagnification = true
        maxMagnification = 8
        minMagnification = 0.001

        let view = PannableImageView(frame: .zero)
        view.image = image
        view.source = source
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel(description.isEmpty ? "Article image" : description)
        let pixels = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        let width = max(image.size.width, CGFloat(pixels?.pixelsWide ?? 0))
        let size = image.size
        if size.width > 0 && size.height > 0 {
            view.setFrameSize(NSSize(width: width, height: width * size.height / size.width))
        }
        documentView = view
    }

    required init?(coder: NSCoder) { nil }

    func apply(_ request: ImageZoomRequest) {
        guard lastRequest != request.id else { return }
        lastRequest = request.id
        switch request.command {
        case .fit:
            fitsWindow = true
            fit()
        case .actualSize:
            fitsWindow = false
            zoom(to: 1)
        case .step(let factor):
            fitsWindow = false
            zoom(to: magnification * factor)
        }
        publishScale()
    }

    override func layout() {
        super.layout()
        if fitsWindow { fit() }
        publishScale()
    }

    override func magnify(with event: NSEvent) {
        fitsWindow = false
        super.magnify(with: event)
        publishScale()
    }

    override func reflectScrolledClipView(_ clipView: NSClipView) {
        super.reflectScrolledClipView(clipView)
        publishScale()
    }

    private func fit() {
        guard let size = documentView?.frame.size, size.width > 0, size.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return }
        let scale = min(1, contentSize.width / size.width, contentSize.height / size.height)
        zoom(to: scale)
    }

    private func zoom(to scale: CGFloat) {
        let next = min(maxMagnification, max(minMagnification, scale))
        guard abs(next - magnification) > 0.00001 else { return }
        let bounds = contentView.bounds
        setMagnification(next, centeredAt: NSPoint(x: bounds.midX, y: bounds.midY))
    }

    private func publishScale() {
        guard lastScale != magnification, reportScale != nil else { return }
        let scale = magnification
        lastScale = scale
        // AppKit can report bounds changes during a SwiftUI layout pass.
        Task { @MainActor [weak self] in
            guard self?.lastScale == scale else { return }
            self?.reportScale?(scale)
        }
    }
}

private final class CenteredImageClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        if let image = documentView?.frame {
            if image.width < bounds.width { bounds.origin.x = image.midX - bounds.width / 2 }
            if image.height < bounds.height { bounds.origin.y = image.midY - bounds.height / 2 }
        }
        return bounds
    }
}

private final class PannableImageView: NSImageView {
    var source: URL?
    private var dragging = false

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragging, let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x -= event.deltaX / scroll.magnification
        origin.y += (clip.isFlipped ? -1 : 1) * event.deltaY / scroll.magnification
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if dragging {
            dragging = false
            NSCursor.pop()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = menu.addItem(withTitle: "Open Image in Browser", action: #selector(openOriginal), keyEquivalent: "")
        item.target = self
        return menu
    }

    @objc private func openOriginal() {
        if let source { NSWorkspace.shared.open(source) }
    }
}
