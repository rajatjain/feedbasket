import AppKit
import SwiftUI
import WebKit

enum AutoReadPreference {
    static let key = "autoReadDelay"
    static let defaultDelay = 2
    static let delays = 1...60
}

private enum ReaderAlignment: String, CaseIterable {
    case left = "Left"
    case justified = "Justified"

    var cssValue: String { self == .justified ? "justify" : "left" }
}

struct ReadingPreferences {
    static let horizontalInset: CGFloat = 28

    var font: String
    var size: Double
    var textAlignment: String
    var lineHeight: Double
    var width: Int

    var cssFont: String {
        switch font {
        case "New York": "ui-serif, Georgia, serif"
        case "System Sans": "-apple-system, sans-serif"
        case "Menlo": "Menlo, monospace"
        default: "Georgia, serif"
        }
    }

    var columnWidth: CGFloat {
        let pointSize = CGFloat(size)
        let font: NSFont
        switch self.font {
        case "New York":
            font = NSFont.systemFont(ofSize: pointSize).fontDescriptor.withDesign(.serif)
                .flatMap { NSFont(descriptor: $0, size: pointSize) } ?? .systemFont(ofSize: pointSize)
        case "System Sans":
            font = .systemFont(ofSize: pointSize)
        case "Menlo":
            font = NSFont(name: "Menlo", size: pointSize) ?? .monospacedSystemFont(ofSize: pointSize, weight: .regular)
        default:
            font = NSFont(name: "Georgia", size: pointSize) ?? .systemFont(ofSize: pointSize)
        }
        let characterWidth = ("0" as NSString).size(withAttributes: [.font: font]).width
        return (characterWidth * CGFloat(width)).rounded()
    }
}

struct ReaderPage: NSViewRepresentable {
    let body: String
    let style: BasketStyle
    let preferences: ReadingPreferences
    let linkedFeeds: [SubscriptionPreview.Candidate]
    let subscribe: (SubscriptionPreview.Candidate) -> Void
    let highlights: [Highlight]
    let targetHighlight: Highlight?
    let bridge: ArticleSelection

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        bridge.webView = view
        view.navigationDelegate = context.coordinator
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let card = PublisherCardStyle.compact
        context.coordinator.feeds = linkedFeeds
        context.coordinator.subscribe = subscribe
        context.coordinator.highlights = highlights
        context.coordinator.target = targetHighlight
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data: https: http:">
        <style>
        html { color-scheme: \(style.scheme == .dark ? "dark" : "light"); }
        body { margin: 0; background: \(style.css(style.readingSurface)); color: \(style.css(BasketTokens.text)); }
        article { max-width: \(preferences.columnWidth)px; margin: 0 auto;
                  padding: 0 \(ReadingPreferences.horizontalInset)px 32px; overflow-wrap: anywhere;
                  font: \(preferences.size)px/\(preferences.lineHeight) \(preferences.cssFont); text-align: \(preferences.textAlignment); }
        article > :first-child { margin-block-start: 0; }
        a { color: \(style.css(style.accentPair)); }
        ::highlight(feedbasket) { background-color: #ffe873; color: #202020; }
        img { max-width: 100%; height: auto; }
        pre { overflow: auto; text-align: left; }
        blockquote { margin-inline: 0; border-left: 2px solid \(style.css(BasketTokens.line)); padding-left: 16px; }
        #linked-feeds { margin-top: 24px; padding-top: 12px; border-top: 1px solid \(style.css(BasketTokens.line));
                        font: 13px/1.5 -apple-system, sans-serif; text-align: left; }
        #linked-feeds summary { cursor: pointer; }
        #linked-feeds ul { display: grid; gap: 4px; list-style: none; padding: 0; margin: 8px 0 0; }
        #linked-feeds li { display: flex; align-items: center; gap: \(card.gap)px;
                          padding: \(card.verticalInset)px \(card.horizontalInset)px;
                          border-radius: \(card.cornerRadius)px; background: \(style.css(PublisherCardStyle.background)); }
        #linked-feeds .publisher-badge { display: grid; place-items: center; flex: 0 0 \(card.badgeSize)px;
                                        height: \(card.badgeSize)px; border-radius: \(card.badgeRadius)px;
                                        background: \(style.css(PublisherCardStyle.badgeBackground(style)));
                                        color: \(style.css(PublisherCardStyle.badgeText));
                                        font: \(PublisherCardStyle.badgeWeight) \(card.badgeFont)px ui-serif, Georgia, serif; }
        #linked-feeds .feed-label { flex: 1; min-width: 0; line-height: 1.25; }
        #linked-feeds strong { display: block; font-weight: 600; }
        #linked-feeds small { display: block; color: \(style.css(PublisherCardStyle.secondaryText)); }
        #linked-feeds a { flex: none; padding: 2px 7px; font-size: 12px; border-radius: 5px;
                          border: 1px solid \(style.css(BasketTokens.line)); text-decoration: none;
                          background: \(style.css(style.readingSurface)); }
        #linked-feeds a:hover { text-decoration: underline; }
        </style></head><body><article>\(body)<details id="linked-feeds" hidden>
        <summary></summary><ul></ul></details></article></body></html>
        """
        if context.coordinator.html != html {
            context.coordinator.html = html
            context.coordinator.loaded = false
            context.coordinator.renderedIDs = nil
            context.coordinator.renderedHighlights = nil
            context.coordinator.renderedTarget = nil
            view.loadHTMLString(html, baseURL: nil)
        } else {
            context.coordinator.updateFooter(in: view)
            context.coordinator.updateHighlights(in: view)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var html = ""
        var loaded = false
        var renderedIDs: [String]?
        var feeds: [SubscriptionPreview.Candidate] = []
        var subscribe: ((SubscriptionPreview.Candidate) -> Void)?
        var highlights: [Highlight] = []
        var target: Highlight?
        var renderedHighlights: [String]?
        var renderedTarget: String?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            updateFooter(in: webView)
            updateHighlights(in: webView)
        }

        func updateHighlights(in webView: WKWebView) {
            let ids = highlights.map(\.id)
            guard loaded, renderedHighlights != ids || renderedTarget != target?.id else { return }
            let jump = renderedTarget != target?.id ? target?.id : nil
            renderedHighlights = ids
            renderedTarget = target?.id
            let marks = highlights.map { mark in
                ["id": mark.id, "quote": mark.quote, "prefix": mark.anchor.prefix ?? "", "suffix": mark.anchor.suffix ?? ""]
            }
            webView.callAsyncJavaScript(ArticleSelection.textIndex + """
                const ranges = [];
                for (const mark of marks) {
                    let index = text.indexOf(mark.quote);
                    while (index !== -1) {
                        const end = index + mark.quote.length;
                        if (text.slice(0, index).endsWith(mark.prefix) && text.startsWith(mark.suffix, end)) {
                            const startNode = nodes.find(node => index < node.end);
                            const endNode = nodes.find(node => end <= node.end);
                            if (!startNode || !endNode) break;
                            const range = new Range();
                            range.setStart(startNode.node, index - startNode.start);
                            range.setEnd(endNode.node, end - endNode.start);
                            ranges.push(range);
                            if (mark.id === target) window.scrollBy(0, range.getBoundingClientRect().top - 90);
                            break;
                        }
                        index = text.indexOf(mark.quote, index + 1);
                    }
                }
                if (CSS.highlights) CSS.highlights.set('feedbasket', new Highlight(...ranges));
                """, arguments: ["marks": marks, "target": jump ?? ""], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func updateFooter(in webView: WKWebView) {
            let ids = feeds.map(\.id)
            guard loaded, renderedIDs != ids else { return }
            renderedIDs = ids
            let rows = feeds.map { feed in
                let publisher = feed.publisher
                return ["title": publisher.title, "domain": publisher.domain, "monogram": publisher.monogram,
                        "action": "feedbasket-subscribe:" + Data(publisher.url.utf8).base64EncodedString()]
            }
            webView.callAsyncJavaScript("""
                const footer = document.getElementById("linked-feeds");
                if (!footer) return;
                footer.hidden = rows.length === 0;
                if (!rows.length) footer.open = false;
                footer.querySelector("summary").textContent = `Feeds linked in this article (${rows.length})`;
                const list = footer.querySelector("ul");
                list.replaceChildren();
                for (const row of rows) {
                    const item = document.createElement("li");
                    const badge = document.createElement("span");
                    const label = document.createElement("div");
                    const title = document.createElement("strong");
                    const domain = document.createElement("small");
                    const action = document.createElement("a");
                    badge.className = "publisher-badge";
                    badge.setAttribute("aria-hidden", "true");
                    badge.textContent = row.monogram;
                    label.className = "feed-label";
                    title.textContent = row.title;
                    domain.textContent = row.domain;
                    action.textContent = "Subscribe";
                    action.setAttribute("aria-label", "Subscribe to " + row.title);
                    action.href = row.action;
                    label.append(title, domain);
                    item.append(badge, label, action);
                    list.append(item);
                }
                """, arguments: ["rows": rows], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.scheme == "feedbasket-subscribe",
                   let data = Data(base64Encoded: String(url.absoluteString.dropFirst("feedbasket-subscribe:".count))),
                   let address = String(data: data, encoding: .utf8),
                   let feed = feeds.first(where: { $0.url == address }) {
                    subscribe?(feed)
                } else if ["http", "https"].contains(url.scheme ?? "") {
                    NSWorkspace.shared.open(url)
                }
            }
            return action.request.url?.absoluteString == "about:blank" && action.navigationType != .linkActivated
                ? .allow : .cancel
        }
    }
}

@MainActor
final class ArticleSelection {
    weak var webView: WKWebView?

    static let textIndex = """
        const article = document.querySelector('article');
        const walker = document.createTreeWalker(article, NodeFilter.SHOW_TEXT, {
            acceptNode: node => node.parentElement.closest('#linked-feeds') ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT
        });
        let text = '';
        const nodes = [];
        while (walker.nextNode()) {
            const node = walker.currentNode;
            const start = text.length;
            text += node.data;
            nodes.push({ node, start, end: text.length });
        }
        """

    func selectedText() async throws -> (quote: String, anchor: Highlight.Anchor)? {
        guard let webView else { return nil }
        let result = try await webView.callAsyncJavaScript(Self.textIndex + """
            const selection = window.getSelection();
            if (!selection?.rangeCount || selection.isCollapsed) return null;
            const range = selection.getRangeAt(0);
            if (!article.contains(range.startContainer) || !article.contains(range.endContainer)) return null;
            const selected = nodes.filter(entry => range.intersectsNode(entry.node));
            if (!selected.length) return null;
            const first = selected[0], last = selected[selected.length - 1];
            const start = first.start + (range.startContainer === first.node ? range.startOffset : 0);
            const end = last.start + (range.endContainer === last.node ? range.endOffset : last.node.length);
            return { quote: text.slice(start, end), prefix: Array.from(text.slice(0, start)).slice(-128).join(''),
                suffix: Array.from(text.slice(end)).slice(0, 128).join('') };
            """, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let result = result as? [String: String], let quote = result["quote"],
              !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard quote.unicodeScalars.count <= 8000 else {
            throw APIError(status: 0, detail: "Select a shorter passage to highlight.")
        }
        return (quote, .init(kind: "article", prefix: result["prefix"] ?? "", suffix: result["suffix"] ?? ""))
    }
}

struct ArticleReader: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    let article: Article
    let highlight: Highlight?
    let isFocused: Bool
    let focus: () -> Void
    let perform: (ArticleAction) -> Void
    @AppStorage("readerFont") private var font = "Georgia"
    @AppStorage("readerSize") private var size = 17.0
    @AppStorage("readerAlign") private var storedAlignment = ReaderAlignment.left.rawValue
    @AppStorage("readerLine") private var lineHeight = 1.65
    @AppStorage("readerWidth") private var width = 62
    @AppStorage(AutoReadPreference.key) private var autoReadDelay = AutoReadPreference.defaultDelay
    @BasketState private var options: Bool = false
    @BasketState private var editingTags: Bool = false
    @BasketState private var tagText: String = ""
    @BasketState private var failure: (articleID: String, detail: String)? = nil
    @BasketState private var retrying = false
    @BasketState private var discoveredFeeds: [SubscriptionPreview.Candidate] = []
    @BasketState private var subscribing: Set<String> = []
    @BasketState private var manuallyChangedReadStatus = false
    @BasketState private var selectionBridge = ArticleSelection()
    @BasketState private var savingHighlight = false

    private var alignment: ReaderAlignment {
        ReaderAlignment(rawValue: storedAlignment) ?? .left
    }

    private var preferences: ReadingPreferences {
        ReadingPreferences(font: font, size: size, textAlignment: alignment.cssValue, lineHeight: lineHeight, width: width)
    }

    var body: some View {
        let preferences = preferences
        VStack(alignment: .leading, spacing: 0) {
            actions
                .padding(.horizontal, BasketTokens.spacing)
                .padding(.vertical, 4)
                .zIndex(1)
            Divider()
            articleHeading
                .padding(.top, 24).padding(.bottom, 20)
                .readerColumn(width: preferences.columnWidth)
            if let html = store.html(for: article.id) {
                ReaderPage(body: html, style: style, preferences: preferences,
                           linkedFeeds: linkedFeeds, subscribe: subscribeToLinkedFeed,
                           highlights: (store.library.highlights ?? [:]).values.filter { $0.article_id == article.id }.sorted { $0.id < $1.id },
                           targetHighlight: highlight, bridge: selectionBridge)
            } else {
                VStack(alignment: .leading, spacing: BasketTokens.spacing) {
                    Text(availability).foregroundStyle(style.color(BasketTokens.muted))
                    if article.content_status == "failed", let failure, failure.articleID == article.id {
                        Text(failure.detail).foregroundStyle(style.color(BasketTokens.muted))
                    }
                    if !article.excerpt.isEmpty { Text(article.excerpt).textSelection(.enabled) }
                    if ["failed", "unavailable"].contains(article.content_status) {
                        HStack(spacing: BasketTokens.spacing) {
                            if let url = article.original {
                                Button("Open Original") { NSWorkspace.shared.open(url) }
                            }
                            if store.canUseAPI && article.location != "trash" {
                                Button("Retry Reader View") {
                                    retrying = true
                                    Task {
                                        defer { retrying = false }
                                        await store.retryReader(article.id)
                                    }
                                }.disabled(retrying)
                            }
                        }.buttonStyle(BasketButton())
                    }
                    Spacer()
                }.readerColumn(width: preferences.columnWidth)
            }
        }
        .task(id: autoReadDelay) { [scope = store.updateScope] in
            guard !article.read, !manuallyChangedReadStatus else { return }
            let delays = AutoReadPreference.delays
            let delay = min(max(autoReadDelay, delays.lowerBound), delays.upperBound)
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard !Task.isCancelled, scope == store.updateScope, !manuallyChangedReadStatus,
                  store.article(article.id)?.read == false else { return }
            store.change(Mutation(articleID: article.id, read: true), automatic: true)
        }
        .task(id: "\(store.updateScope)-\(article.id)-\(article.content_status)-\(store.canUseAPI)") {
            failure = nil
            if let detail = await store.loadReader(article), !Task.isCancelled {
                failure = (article.id, detail)
            }
        }
        .task(id: "\(store.updateScope)-\(article.id)-\(article.content_status)-\(article.body_bytes)-\(store.canUseAPI)") {
            discoveredFeeds = []
            guard store.canUseAPI, article.content_status == "ready" else { return }
            do {
                let feeds = try await store.linkedFeeds(for: article.id)
                try Task.checkCancellation()
                discoveredFeeds = feeds
            } catch {
                // Suggestions are optional and the reader remains available if a lookup fails.
            }
        }
        .alert("Edit tags", isPresented: $editingTags) {
            TextField("Comma-separated tags", text: $tagText)
            Button("Save") {
                do { store.change(Mutation(articleID: article.id, tags: try LibraryTags.parse(tagText))) }
                catch { store.report(error) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var linkedFeeds: [SubscriptionPreview.Candidate] {
        let subscriptions = Set(store.library.feeds.values.map(\.url))
        return discoveredFeeds.filter { !subscriptions.contains($0.url) }
    }

    private func saveSelectedHighlight() {
        savingHighlight = true
        Task {
            defer { savingHighlight = false }
            do {
                guard let selection = try await selectionBridge.selectedText() else {
                    store.notify("Select text to highlight.", icon: "highlighter")
                    return
                }
                try await store.saveHighlight(article: article, mark: .highlight, quote: selection.quote, anchor: selection.anchor)
            } catch { store.report(error) }
        }
    }

    private func subscribeToLinkedFeed(_ candidate: SubscriptionPreview.Candidate) {
        guard store.canUseAPI, subscribing.insert(candidate.url).inserted else { return }
        Task {
            defer { subscribing.remove(candidate.url) }
            do {
                _ = try await store.subscribe(url: candidate.url, title: candidate.title, website: false)
                discoveredFeeds.removeAll { $0.url == candidate.url }
            } catch { store.report(error) }
        }
    }

    private var articleHeading: some View {
        VStack(alignment: .leading, spacing: BasketTokens.spacing) {
            HStack(spacing: 6) {
                Text(article.source).fontWeight(.semibold).foregroundStyle(style.accent)
                Text("·").accessibilityHidden(true)
                Text(article.date, style: .date)
            }
            .font(.system(size: BasketTokens.labelSize))
            .foregroundStyle(style.color(BasketTokens.muted))
            Text(article.title)
                .font(.system(size: 29, weight: .semibold, design: .serif))
                .textSelection(.enabled)
                .accessibilityAddTraits(.isHeader)
            HStack {
                Text(article.read ? "Read" : "Unread")
                if store.offline(article.id) { Label("Text available offline", systemImage: "arrow.down.circle") }
            }
            .font(.system(size: BasketTokens.labelSize))
            .foregroundStyle(style.color(BasketTokens.muted))
            if !article.tags.isEmpty { Text(article.tags.joined(separator: " · ")).foregroundStyle(style.accent) }
        }
    }

    private var availability: String {
        if !store.canUseAPI { return "This article has no offline copy." }
        switch article.content_status {
        case "pending": return "Preparing the reader view…"
        case "failed": return "Couldn’t prepare the reader view."
        case "quota": return "The backend storage limit has been reached."
        case "pdf_unsupported": return "Add the original link as a PDF to open it in the PDF reader."
        default: return "Reader content is unavailable."
        }
    }

    private var actions: some View {
        HStack(spacing: 3) {
            toolbarButton("Reading appearance", icon: "textformat", tooltipAlignment: .bottomLeading) { options.toggle() }
                .popover(isPresented: $options) { appearanceOptions }
            toolbarButton(isFocused ? "Exit Focus Mode" : "Enter Focus Mode",
                          icon: isFocused ? "arrow.down.right.and.arrow.up.left" : "viewfinder",
                          active: isFocused, shortcut: isFocused ? "Esc" : nil,
                          tooltipAlignment: .bottomLeading, action: focus)
            Spacer(minLength: 2)
            Divider().frame(height: 16).padding(.horizontal, 3)

            if article.location != "trash", store.html(for: article.id) != nil {
                toolbarButton("Highlight selected text", icon: "highlighter", action: saveSelectedHighlight)
                    .disabled(!store.canUseAPI || savingHighlight)
            }

            toolbarButton(article.read ? "Mark as unread" : "Mark as read",
                          icon: article.read ? "envelope.badge" : "envelope.open") {
                if let latest = store.article(article.id),
                   store.change(Mutation(articleID: latest.id, read: !latest.read)) {
                    manuallyChangedReadStatus = true
                }
            }
            if ArticleAction.star.allows(article) {
                toolbarButton(ArticleAction.star.title(for: article), icon: article.isStarred ? "star.fill" : "star",
                              active: article.isStarred, shortcut: ArticleAction.star.shortcut) { perform(.star) }
            }
            if ArticleAction.archive.allows(article) {
                toolbarButton("Archive", icon: "archivebox", shortcut: ArticleAction.archive.shortcut) { perform(.archive) }
            } else {
                toolbarButton("Restore", icon: "arrow.uturn.backward") {
                    store.change(Mutation(articleID: article.id, action: "restore"))
                }
            }
            if ArticleAction.dislike.allows(article) {
                toolbarButton(ArticleAction.dislike.title(), icon: "hand.thumbsdown",
                              shortcut: ArticleAction.dislike.shortcut) { perform(.dislike) }
            }
            toolbarButton("Edit tags", icon: "tag", tooltipAlignment: article.original == nil ? .bottomTrailing : .bottom) {
                tagText = article.tags.joined(separator: ", ")
                editingTags = true
            }

            if let url = article.original {
                Divider().frame(height: 16).padding(.horizontal, 3)
                toolbarButton("Open original", icon: "arrow.up.right.square", tooltipAlignment: .bottomTrailing) {
                    NSWorkspace.shared.open(url)
                }
                Menu {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    } label: {
                        Label("Copy Link", systemImage: "link")
                    }
                    ShareLink(item: url) { Text("Share…") }
                } label: {
                    Label("Share article", systemImage: "square.and.arrow.up")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .modifier(ReaderTooltip(title: "Share article", shortcut: nil, alignment: .bottomTrailing))
            }
        }
        .buttonStyle(ReaderToolbarButtonStyle())
    }

    private func toolbarButton(_ title: String, icon: String, active: Bool = false, shortcut: String? = nil,
                               tooltipAlignment: Alignment = .bottom, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly) }
            .foregroundStyle(active ? style.accent : style.color(BasketTokens.text))
            .modifier(ReaderTooltip(title: title, shortcut: shortcut, alignment: tooltipAlignment))
    }

    private var appearanceOptions: some View {
        Form {
            Picker("Font", selection: $font) {
                ForEach(["Georgia", "New York", "System Sans", "Menlo"], id: \.self) { Text($0) }
            }
            Picker("Text size", selection: $size) {
                Text("Small").tag(15.0); Text("Medium").tag(17.0); Text("Large").tag(20.0); Text("Extra large").tag(24.0)
            }
            Picker("Alignment", selection: Binding(get: { alignment }, set: { storedAlignment = $0.rawValue })) {
                ForEach(ReaderAlignment.allCases, id: \.self) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            Picker("Line spacing", selection: $lineHeight) {
                Text("Compact").tag(1.4); Text("Standard").tag(1.65); Text("Relaxed").tag(1.9)
            }
            Picker("Column width", selection: $width) {
                Text("Narrow").tag(48); Text("Standard").tag(62); Text("Wide").tag(78)
            }
        }.padding().frame(width: 275)
    }
}

private struct ReaderTooltip: ViewModifier {
    @Environment(\.basketStyle) private var style
    @BasketState private var hovering = false
    @BasketState private var visible = false

    let title: String
    let shortcut: String?
    let alignment: Alignment

    func body(content: Content) -> some View {
        content
            .accessibilityHint(shortcut.map { "Keyboard shortcut \($0)" } ?? "")
            .onHover { inside in
                hovering = inside
                if !inside { visible = false }
            }
            .task(id: hovering) {
                guard hovering else { return }
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                if hovering && !Task.isCancelled { visible = true }
            }
            .overlay(alignment: alignment) {
                if visible {
                    HStack(spacing: 6) {
                        Text(title)
                        if let shortcut {
                            Text(shortcut).foregroundStyle(style.color(BasketTokens.muted))
                        }
                    }
                    .font(.system(size: BasketTokens.labelSize))
                    .foregroundStyle(style.color(BasketTokens.text))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(style.color(BasketTokens.surface), in: .rect(cornerRadius: BasketTokens.radius))
                    .overlay {
                        RoundedRectangle(cornerRadius: BasketTokens.radius).strokeBorder(style.color(BasketTokens.line))
                    }
                    .fixedSize()
                    .visualEffect { tooltip, geometry in
                        tooltip.offset(y: geometry.size.height + 9)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

private extension View {
    func readerColumn(width: CGFloat) -> some View {
        frame(maxWidth: width, alignment: .leading)
            .padding(.horizontal, ReadingPreferences.horizontalInset)
            .frame(maxWidth: .infinity)
    }
}

private struct ReaderToolbarButtonStyle: ButtonStyle {
    @Environment(\.basketStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .frame(width: 30, height: 30)
            .background(configuration.isPressed ? style.color(BasketTokens.subtle) : .clear,
                        in: RoundedRectangle(cornerRadius: BasketTokens.radius))
            .contentShape(Rectangle())
    }
}
