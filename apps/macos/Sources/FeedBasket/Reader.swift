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
    let articleID: String
    let body: String
    let style: BasketStyle
    let preferences: ReadingPreferences
    let linkedFeeds: [SubscriptionPreview.Candidate]
    let subscribe: (SubscriptionPreview.Candidate) -> Void
    let highlights: [Highlight]
    let targetHighlight: Highlight?
    let canHighlight: Bool
    let saveHighlight: (String, Highlight.Anchor) -> Void
    let restartReader: RestartReaderState

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "articleHighlight")
        configuration.userContentController.addUserScript(WKUserScript(
            source: ArticleSelection.actionScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "articleHighlight", contentWorld: .defaultClient)
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        let card = PublisherCardStyle.compact
        let coordinator = context.coordinator
        coordinator.articleID = articleID
        coordinator.restartReader = restartReader
        restartReader.capture = (articleID, { [articleID, weak coordinator, weak view] in
            guard let coordinator, coordinator.loaded, let view,
                  let position = await ArticleRestartPosition.capture(in: view) else { return nil }
            return .article(id: articleID, position: position)
        })
        context.coordinator.feeds = linkedFeeds
        context.coordinator.subscribe = subscribe
        context.coordinator.highlights = highlights
        context.coordinator.target = targetHighlight
        context.coordinator.canHighlight = canHighlight
        context.coordinator.saveHighlight = saveHighlight
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
        #selection-highlight { position: fixed; z-index: 1; padding: 5px \(BasketTokens.spacing)px;
                               border: 1px solid \(style.css(BasketTokens.line));
                               border-radius: \(BasketTokens.radius)px; white-space: nowrap;
                               font: 500 \(BasketTokens.bodySize)px -apple-system, sans-serif;
                               background: \(style.css(BasketTokens.surface)); color: \(style.css(style.accentPair)); }
        #selection-highlight:hover { background: \(style.css(BasketTokens.subtle)); }
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
        <summary></summary><ul></ul></details></article>
        <button id="selection-highlight" type="button" hidden>Highlight</button></body></html>
        """
        if context.coordinator.html != html {
            context.coordinator.html = html
            context.coordinator.loaded = false
            context.coordinator.renderedIDs = nil
            context.coordinator.renderedHighlights = nil
            context.coordinator.renderedTarget = nil
            context.coordinator.highlightEnabled = nil
            context.coordinator.pendingNavigation = view.loadHTMLString(html, baseURL: nil)
        } else {
            context.coordinator.updateHighlightAvailability(in: view)
            context.coordinator.updateFooter(in: view)
            context.coordinator.updateHighlights(in: view)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var articleID: String?
        weak var restartReader: RestartReaderState?
        var html = ""
        var loaded = false
        var renderedIDs: [String]?
        var feeds: [SubscriptionPreview.Candidate] = []
        var subscribe: ((SubscriptionPreview.Candidate) -> Void)?
        var highlights: [Highlight] = []
        var target: Highlight?
        var renderedHighlights: [String]?
        var renderedTarget: String?
        var canHighlight = false
        var highlightEnabled: Bool?
        var saveHighlight: ((String, Highlight.Anchor) -> Void)?
        var pendingNavigation: WKNavigation?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation == pendingNavigation else { return }
            loaded = true
            updateHighlightAvailability(in: webView)
            updateFooter(in: webView)
            if case .article(let id, let position) = restartReader?.pending, id == articleID {
                restartReader?.pending = nil
                updateHighlights(in: webView, jumpToTarget: false)
                ArticleRestartPosition.restore(position, in: webView)
            } else {
                updateHighlights(in: webView)
            }
        }

        func updateHighlightAvailability(in webView: WKWebView) {
            guard loaded, highlightEnabled != canHighlight else { return }
            highlightEnabled = canHighlight
            webView.callAsyncJavaScript("window.feedbasketHighlightEnabled?.(enabled);",
                arguments: ["enabled": canHighlight], in: nil, in: .defaultClient, completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard loaded, canHighlight, message.frameInfo.isMainFrame,
                  let selection = message.body as? [String: String], let quote = selection["quote"],
                  !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            saveHighlight?(quote, .init(kind: "article", prefix: selection["prefix"] ?? "", suffix: selection["suffix"] ?? ""))
        }

        func updateHighlights(in webView: WKWebView, jumpToTarget: Bool = true) {
            let ids = highlights.map(\.id)
            guard loaded, renderedHighlights != ids || renderedTarget != target?.id else { return }
            let jump = jumpToTarget && renderedTarget != target?.id ? target?.id : nil
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

enum ArticleSelection {
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

    static let actionScript = """
        (() => {
        const articleBody = document.querySelector('article');
        const button = document.getElementById('selection-highlight');
        if (!articleBody || !button) return;
        let enabled = false;
        let selectedRange;
        function update() {
            const selection = window.getSelection();
            selectedRange = undefined;
            if (enabled && selection?.rangeCount && !selection.isCollapsed && selection.toString().trim()) {
                const range = selection.getRangeAt(0);
                const footer = document.getElementById('linked-feeds');
                if (articleBody.contains(range.startContainer) && articleBody.contains(range.endContainer)
                    && !footer.contains(range.startContainer) && !footer.contains(range.endContainer)) {
                    selectedRange = range.cloneRange();
                }
            }
            position();
        }
        function position() {
            const lines = selectedRange ? Array.from(selectedRange.getClientRects()).filter(rect => rect.width > 0) : [];
            const first = lines[0], last = lines.at(-1);
            button.hidden = !first || last.bottom <= 0 || first.top >= window.innerHeight;
            if (button.hidden) return;
            const inset = 6;
            const above = first.top - button.offsetHeight - inset;
            const fitsAbove = above >= inset;
            const anchor = fitsAbove ? first : last;
            const left = anchor.left + (anchor.width - button.offsetWidth) / 2;
            button.style.left = `${Math.max(inset, Math.min(left, window.innerWidth - button.offsetWidth - inset))}px`;
            const below = last.bottom + inset;
            button.style.top = `${fitsAbove ? above : Math.min(below, window.innerHeight - button.offsetHeight - inset)}px`;
        }
        window.feedbasketHighlightEnabled = value => { enabled = value; update(); };
        document.addEventListener('selectionchange', update);
        window.addEventListener('scroll', position, true);
        window.addEventListener('resize', position);
        window.addEventListener('load', position);
        new ResizeObserver(position).observe(articleBody);
        button.addEventListener('mousedown', event => event.preventDefault());
        button.addEventListener('click', () => {
            const range = selectedRange;
            if (!enabled || !range || !articleBody.contains(range.commonAncestorContainer)) return;
            \(textIndex)
            const selected = nodes.filter(entry => range.intersectsNode(entry.node));
            if (!selected.length) return;
            const first = selected[0], last = selected[selected.length - 1];
            const start = first.start + (range.startContainer === first.node ? range.startOffset : 0);
            const end = last.start + (range.endContainer === last.node ? range.endOffset : last.node.length);
            const quote = text.slice(start, end);
            window.webkit.messageHandlers.articleHighlight.postMessage({
                quote, prefix: Array.from(text.slice(0, start)).slice(-128).join(''),
                suffix: Array.from(text.slice(end)).slice(0, 128).join('')
            });
            window.getSelection().removeAllRanges();
            update();
        });
        })();
        """
}

struct ArticleReader: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    let article: Article
    let highlight: Highlight?
    let isFocused: Bool
    let focus: () -> Void
    let perform: (ArticleAction) -> Void
    let restartReader: RestartReaderState
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
                ReaderPage(articleID: article.id, body: html, style: style, preferences: preferences,
                           linkedFeeds: linkedFeeds, subscribe: subscribeToLinkedFeed,
                           highlights: (store.library.highlights ?? [:]).values.filter { $0.article_id == article.id }.sorted { $0.id < $1.id },
                           targetHighlight: highlight,
                           canHighlight: store.canUseAPI && article.location != "trash" && !savingHighlight,
                           saveHighlight: saveSelectedHighlight, restartReader: restartReader)
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

    private func saveSelectedHighlight(_ quote: String, _ anchor: Highlight.Anchor) {
        guard !savingHighlight, store.canUseAPI, article.location != "trash" else { return }
        guard quote.unicodeScalars.count <= 8000 else {
            store.report(APIError(status: 0, detail: "Select a shorter passage to highlight."))
            return
        }
        savingHighlight = true
        Task {
            defer { savingHighlight = false }
            do {
                try await store.saveHighlight(article: article, mark: .highlight, quote: quote, anchor: anchor)
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

struct ReaderToolbarButtonStyle: ButtonStyle {
    @Environment(\.basketStyle) private var style
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .medium))
            .frame(width: 30, height: 30)
            .background(configuration.isPressed || active ? style.color(BasketTokens.subtle) : .clear,
                        in: RoundedRectangle(cornerRadius: BasketTokens.radius))
            .contentShape(Rectangle())
    }
}
