import AppKit
import CryptoKit
import PDFKit
import SwiftUI

struct PDFReader: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    let article: Article
    let highlight: Highlight?
    let tags: [String]
    let isFocused: Bool
    let focus: () -> Void
    let perform: (ArticleAction) -> Void
    let delete: () -> Void
    let leave: () -> Void
    let restartReader: RestartReaderState

    @BasketState private var reader = PDFReaderController()
    @BasketState private var thumbnails = true
    @BasketState private var focusThumbnails = false
    @BasketState private var editingTags = false
    @BasketState private var query = ""
    @BasketState private var finding = false
    @BasketState private var findFocusRequest = 0
    @BasketState private var error: String?
    @BasketState private var retry = 0
    @BasketState private var savingMark = false
    @BasketState private var password = ""
    @BasketState private var lockedPDF: LockedPDF?

    private var restartPosition: RestartSnapshot.PDFPosition? {
        guard case .pdf(let id, let position) = restartReader.pending, id == article.id else { return nil }
        return position
    }

    private var showThumbnails: Bool { isFocused ? focusThumbnails : thumbnails }
    private var canMark: Bool { article.location != "trash" && store.canUseAPI && !savingMark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            readerContent
        }
        .background(style.color(style.readingSurface))
        .task(id: LoadKey(retry: retry, pending: article.pdf?.deletion_pending, online: article.pdf?.source != "link" && store.canUseAPI)) {
            await load()
        }
        .onChange(of: highlight?.id) { reader.jump(to: highlight) }
        .onChange(of: marks.map(\.id)) { reader.showMarks(marks) }
        .onAppear {
            let thumbnails = isFocused ? $focusThumbnails : $thumbnails
            if let restartPosition { thumbnails.wrappedValue = restartPosition.thumbnails }
            restartReader.capture = (article.id, { [weak controller = reader, thumbnails, id = article.id] in
                guard let position = controller?.positionForRestart(thumbnails: thumbnails.wrappedValue) else { return nil }
                return .pdf(id: id, position: position)
            })
        }
        .onDisappear {
            reader.flushPosition()
            reader.clearSearch()
        }
        .task(id: finding ? query : nil) { [query] in
            guard finding else { return }
            do { try await Task.sleep(for: .milliseconds(180)) }
            catch { return }
            reader.search(query)
        }
        .onChange(of: query) { if !reader.hasSearch(for: query) { reader.clearSearch() } }
        .onChange(of: article.pdf?.deletion_pending) {
            if article.pdf?.deletion_pending == true { closeFind() }
        }
        .onExitCommand {
            if finding { closeFind() }
            else { leave() }
        }
        .popover(isPresented: $editingTags) {
            LibraryTagEditor(tags: article.tags) { tags in
                store.change(Mutation(articleID: article.id, tags: tags))
            }
        }
    }

    @ViewBuilder private var readerContent: some View {
        if article.pdf?.deletion_pending == true {
            BasketEmpty(title: "Deleting PDF…", icon: "trash")
        } else if let document = reader.document {
            HStack(spacing: 0) {
                if showThumbnails { thumbnailRail(document); Divider() }
                pdfPage(document)
            }
            if let error {
                Text(error).foregroundStyle(.red).padding(.horizontal, 10).padding(.vertical, 5)
            }
        } else if let lockedPDF {
            ContentUnavailableView {
                Label("PDF is password protected", systemImage: "lock.doc")
            } description: {
                if let error { Text(error).foregroundStyle(.red) }
            } actions: {
                SecureField("PDF password", text: $password).frame(width: 205).onSubmit { unlock(lockedPDF) }
                Button("Unlock") { unlock(lockedPDF) }.buttonStyle(BasketButton(primary: true)).disabled(password.isEmpty)
            }
        } else if let error {
            ContentUnavailableView {
                Label("Couldn’t open PDF", systemImage: "doc.richtext")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { retry += 1 }.buttonStyle(BasketButton())
            }
        } else {
            ProgressView("Opening PDF…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private struct LockedPDF {
        let document: PDFDocument
        let revision: String
    }

    private struct LoadKey: Equatable {
        let retry: Int
        let pending: Bool?
        let online: Bool
    }

    private var marks: [Highlight] {
        (store.library.highlights ?? [:]).values.filter { $0.article_id == article.id }.sorted { $0.id < $1.id }
    }

    private var header: some View {
        Group {
            if let document = reader.document, article.pdf?.deletion_pending != true, !isFocused {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: BasketTokens.spacing) {
                        heading(stacked: true, compact: false).frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
                        navigation(document)
                        documentActions.frame(minWidth: 140, maxWidth: .infinity, alignment: .trailing)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        identityRow
                        navigation(document).frame(maxWidth: .infinity)
                    }
                }
            } else {
                identityRow
            }
        }
        .padding(.horizontal, BasketTokens.spacing)
        .padding(.vertical, 3)
    }

    private var identityRow: some View {
        HStack(spacing: BasketTokens.spacing) {
            heading(stacked: false, compact: true)
            Spacer(minLength: 6)
            documentActions
        }
    }

    private func heading(stacked: Bool, compact: Bool) -> some View {
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(spacing: BasketTokens.spacing))
        return layout {
            Text(article.title)
                .font(.headline)
                .lineLimit(1)
                .help(article.title)
                .accessibilityAddTraits(.isHeader)
                .layoutPriority(1)
            if !article.tags.isEmpty {
                TagLabel(tag: article.tags.joined(separator: " · "))
                    .lineLimit(1)
                    .frame(maxWidth: compact ? 110 : 150, alignment: .leading)
            }
        }
    }

    private var documentActions: some View {
        HStack(spacing: 3) {
            if reader.document != nil && article.pdf?.deletion_pending != true {
                PDFToolbarButton(title: "Find in PDF (⌘F)", icon: "magnifyingglass", active: finding, action: showFind)
                    .keyboardShortcut("f")
                Divider().frame(height: 15).padding(.horizontal, 2)
            }
            if article.location != "trash", article.pdf?.deletion_pending != true {
                PDFToolbarButton(title: "Edit tags", icon: "tag") {
                    editingTags = true
                }
                Menu {
                    Button(article.read ? "Mark as unread" : "Mark as read") {
                        store.change(Mutation(articleID: article.id, read: !article.read))
                    }
                    Button(ArticleAction.star.title(for: article)) { perform(.star) }
                    if ArticleAction.archive.allows(article) {
                        Button("Archive") { perform(.archive) }
                    } else {
                        Button("Restore to Read Later") { store.change(Mutation(articleID: article.id, action: "restore")) }
                    }
                    Button("Move to Trash", role: .destructive) { perform(.trash) }
                    if article.pdf?.source == "link", let url = article.original {
                        Button("Open original") { NSWorkspace.shared.open(url) }
                    }
                } label: {
                    Label("PDF actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                        .font(.system(size: 15, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 28)
                .help("PDF actions")
            }
            if article.location == "trash" && article.pdf?.deletion_pending != true {
                Button("Restore") { store.change(Mutation(articleID: article.id, action: "restore")) }
                    .buttonStyle(BasketButton())
                Button("Delete Permanently…", role: .destructive, action: delete)
                    .buttonStyle(BasketButton()).disabled(!store.canUseAPI)
            }
            PDFToolbarButton(title: isFocused ? "Exit Focus Mode" : "Enter Focus Mode",
                             icon: isFocused ? "arrow.down.right.and.arrow.up.left" : "viewfinder",
                             active: isFocused, action: changeFocus)
        }
        .fixedSize()
    }

    private func navigation(_ document: PDFDocument) -> some View {
        HStack(spacing: 7) {
            if !isFocused { thumbnailButton }
            PDFPageControl(page: reader.page, count: document.pageCount, go: reader.go)
            Divider().frame(height: 16)
            if isFocused {
                PDFToolbarButton(title: "Zoom out", icon: "minus.magnifyingglass") { reader.zoom(inward: false) }
            }
            Menu {
                Button("Fit width") { reader.fit(.width) }
                Button("Fit page") { reader.fit(.page) }
                Button("Actual size") { reader.actualSize() }
                if !isFocused {
                    Divider()
                    Button("Zoom in") { reader.zoom(inward: true) }
                    Button("Zoom out") { reader.zoom(inward: false) }
                }
            } label: {
                Label(reader.zoomLabel, systemImage: "arrow.up.left.and.arrow.down.right")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: BasketTokens.labelSize, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 6)
            .frame(height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: BasketTokens.radius).strokeBorder(style.color(BasketTokens.line))
                    .allowsHitTesting(false)
            }
            .fixedSize()
            .help("Zoom options")
            if isFocused {
                PDFToolbarButton(title: "Zoom in", icon: "plus.magnifyingglass") { reader.zoom(inward: true) }
                Divider().frame(height: 16)
                thumbnailButton
            }
        }
        .fixedSize()
    }

    private var thumbnailButton: some View {
        PDFToolbarButton(title: showThumbnails ? "Hide thumbnails" : "Show thumbnails",
                         icon: "sidebar.left", active: showThumbnails) {
            if isFocused { focusThumbnails.toggle() }
            else { thumbnails.toggle() }
        }
    }

    private func pdfPage(_ document: PDFDocument) -> some View {
        PDFCanvas(reader: reader, canMark: canMark, mark: save)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                PDFPageOverlays(selection: canMark ? reader.selectionBounds : nil, matches: reader.matchBounds, mark: save)
            }
            .overlay(alignment: .bottom) {
                if isFocused {
                    navigation(document)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 6)
                        .modifier(PDFToolbarPanel())
                        .padding(.bottom, 12)
                }
            }
            .overlay(alignment: .topTrailing) {
                if finding {
                    PDFFindPanel(query: $query, focusRequest: findFocusRequest, status: reader.searchStatus,
                                 canNavigate: reader.matchCount > 0, submit: submitFind,
                                 step: reader.stepMatch, close: closeFind)
                        .padding(8)
                        .zIndex(1)
                }
            }
    }

    private func changeFocus() {
        if let position = reader.positionForRestart(thumbnails: thumbnails) {
            restartReader.pending = .pdf(id: article.id, position: position)
        }
        focus()
    }

    private func showFind() {
        finding = true
        findFocusRequest += 1
    }

    private func submitFind() {
        if reader.hasSearch(for: query) { reader.stepMatch(1) }
        else { reader.search(query) }
    }

    private func closeFind() {
        finding = false
        query = ""
        reader.clearSearch()
    }

    private func thumbnailRail(_ document: PDFDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 7) {
                    ForEach(1...document.pageCount, id: \.self) { number in
                        if let page = document.page(at: number - 1) {
                            Button { reader.go(to: number) } label: {
                                VStack(spacing: 4) {
                                    Image(nsImage: page.thumbnail(of: NSSize(width: 70, height: 90), for: .cropBox))
                                    Text(String(number)).font(.caption)
                                }
                                .frame(width: 88)
                                .padding(.vertical, 4)
                                .background(reader.page == number ? style.selection : .clear, in: .rect(cornerRadius: 5))
                                .foregroundStyle(reader.page == number ? style.selectionText : style.color(BasketTokens.text))
                            }.buttonStyle(.plain).accessibilityLabel("Page \(number)").id(number)
                        }
                    }
                }.padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(reader.page, anchor: .center) }
            .onChange(of: reader.page) { proxy.scrollTo(reader.page, anchor: .center) }
        }.frame(width: 103).background(style.color(style.palette.sidebar))
    }

    private func load() async {
        guard article.pdf?.deletion_pending != true, reader.document == nil, lockedPDF == nil else { return }
        error = nil
        let scope = store.updateScope
        do {
            let url = try await store.pdfURL(for: article)
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
            request.setValue("application/pdf", forHTTPHeaderField: "Accept")
            let (location, response) = try await URLSession.shared.download(for: request)
            defer { try? FileManager.default.removeItem(at: location) }
            try Task.checkCancellation()
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                throw APIError(status: 0, detail: "The PDF could not be downloaded.")
            }
            let data = try Data(contentsOf: location, options: .mappedIfSafe)
            guard let document = PDFDocument(data: data), document.isLocked || document.pageCount > 0 else {
                throw APIError(status: 0, detail: "The file isn’t a readable PDF.")
            }
            let revision = await Task.detached(priority: .utility) {
                SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }.value
            try Task.checkCancellation()
            guard scope == store.updateScope else { return }
            if let expected = article.pdf?.document_revision, expected != revision {
                throw APIError(status: 0, detail: "The downloaded PDF doesn’t match the saved file.")
            }
            if document.isLocked { lockedPDF = LockedPDF(document: document, revision: revision) }
            else { open(document, revision: revision) }
        } catch {
            if !Task.isCancelled && scope == store.updateScope { self.error = error.localizedDescription }
        }
    }

    private func unlock(_ pdf: LockedPDF) {
        defer { password = "" }
        guard pdf.document.unlock(withPassword: password) else { error = "Incorrect PDF password."; return }
        guard pdf.document.pageCount > 0 else {
            error = "This PDF has no readable pages."
            lockedPDF = nil
            return
        }
        error = nil
        lockedPDF = nil
        open(pdf.document, revision: pdf.revision)
    }

    private func open(_ document: PDFDocument, revision: String) {
        let scope = store.updateScope
        let resume = restartPosition
        if resume != nil { restartReader.pending = nil }
        reader.open(document, revision: revision, position: store.readingPosition(for: article),
                    highlight: highlight, marks: marks, resume: resume) { position in
            store.rememberPDFPosition(position, articleID: article.id, scope: scope)
        }
    }

    private func save(_ mark: Highlight.Mark) {
        guard canMark, let selection = reader.selectedText() else { return }
        let selectedPassage = reader.view?.currentSelection
        savingMark = true
        error = nil
        Task {
            defer { savingMark = false }
            do {
                try await store.saveHighlight(article: article, mark: mark, quote: selection.quote, anchor: selection.anchor)
                if reader.view?.currentSelection === selectedPassage { reader.view?.clearSelection() }
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
}

private struct PDFCanvas: NSViewRepresentable {
    @Environment(\.basketStyle) private var style
    let reader: PDFReaderController
    let canMark: Bool
    let mark: (Highlight.Mark) -> Void

    func makeNSView(context: Context) -> AnnotatablePDFView {
        let view = AnnotatablePDFView()
        view.displayMode = .singlePageContinuous
        view.displayBox = .cropBox
        view.autoScales = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        view.geometryChanged = { [weak reader] in reader?.layoutChanged() }
        reader.attach(view)
        return view
    }

    func updateNSView(_ view: AnnotatablePDFView, context: Context) {
        view.backgroundColor = NSColor(style.color(style.palette.sidebar))
        view.mark = canMark ? mark : nil
    }
}

private final class AnnotatablePDFView: PDFView {
    var mark: ((Highlight.Mark) -> Void)?
    var geometryChanged: (() -> Void)?

    override func layout() {
        super.layout()
        geometryChanged?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let selection = currentSelection
        let menu = super.menu(for: event) ?? NSMenu()
        if mark != nil, let selection, selection.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            // PDFView can clear the selection when the user right-clicks.
            if currentSelection == nil { setCurrentSelection(selection, animate: false) }
            if !menu.items.isEmpty { menu.insertItem(.separator(), at: 0) }
            for (index, action) in [#selector(highlightSelection), #selector(underlineSelection)].enumerated() {
                let item = NSMenuItem(title: index == 0 ? "Highlight" : "Underline", action: action, keyEquivalent: "")
                item.target = self
                menu.insertItem(item, at: index)
            }
        }
        return menu
    }

    @objc private func highlightSelection() { mark?(.highlight) }
    @objc private func underlineSelection() { mark?(.underline) }
}

@MainActor @Observable
final class PDFReaderController: NSObject {
    enum Fit { case width, page }

    private(set) var document: PDFDocument?
    private(set) var page = 1
    private(set) var selectionBounds: CGRect?
    private(set) var matchBounds: [CGRect] = []
    private(set) var matchCount = 0
    private(set) var zoomLabel = "Fit width"
    private var matchIndex: Int?
    private var isSearching = false
    private var submittedQuery = ""

    var searchStatus: String {
        if isSearching { return "Searching…" }
        if submittedQuery.isEmpty { return "" }
        return matchIndex.map { "\($0 + 1) of \(matchCount)" } ?? "No matches"
    }

    @ObservationIgnored private(set) weak var view: PDFView?
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var initialPosition: ReadingPosition?
    @ObservationIgnored private var initialHighlight: Highlight?
    @ObservationIgnored private var restartPosition: RestartSnapshot.PDFPosition?
    @ObservationIgnored private var onPosition: ((ReadingPosition) -> Void)?
    @ObservationIgnored private var appliedMarks: [String: [(PDFPage, PDFAnnotation)]] = [:]
    @ObservationIgnored private var lastPosition: ReadingPosition?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var observingPosition = false
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var geometryTask: Task<Void, Never>?
    @ObservationIgnored private var fitMode: Fit? = .width
    @ObservationIgnored private var fitViewport: CGSize?

    func open(_ document: PDFDocument, revision: String, position: ReadingPosition?, highlight: Highlight?,
              marks: [Highlight], resume: RestartSnapshot.PDFPosition?, onPosition: @escaping (ReadingPosition) -> Void) {
        self.revision = revision
        initialPosition = position?.document_revision == nil || position?.document_revision == revision ? position : nil
        initialHighlight = highlight
        restartPosition = resume?.revision == revision ? resume : nil
        self.onPosition = onPosition
        self.document = document
        showMarks(marks)
    }

    func attach(_ view: PDFView) {
        flushPosition()
        if let previous = self.view {
            let center = NotificationCenter.default
            center.removeObserver(self, name: nil, object: previous)
            if let clip = previous.documentView?.enclosingScrollView?.contentView {
                center.removeObserver(self, name: nil, object: clip)
            }
        }
        self.view = view
        view.document = document
        fitViewport = nil
        observingPosition = false
        Task { @MainActor [weak self, weak view] in
            guard let self, let view, self.view === view else { return }
            view.layoutSubtreeIfNeeded()
            let resume = restartPosition
            restartPosition = nil
            if let position = resume, position.page > 0, let target = document?.page(at: position.page - 1) {
                if position.fitPage == true {
                    fitMode = .page
                    applyFit(to: view)
                } else if let scale = position.scale, scale.isFinite, scale > 0 {
                    fitMode = nil
                    view.autoScales = false
                    view.scaleFactor = scale
                } else {
                    applyFit(to: view)
                }
                view.layoutSubtreeIfNeeded()
                view.go(to: PDFDestination(page: target, at: position.point))
            } else {
                applyFit(to: view)
                view.layoutSubtreeIfNeeded()
                if let pos = lastPosition { navigate(page: pos.page, offset: pos.offset) }
                else if let highlight = initialHighlight { jump(to: highlight) }
                else if let pos = initialPosition { navigate(page: pos.page, offset: pos.offset) }
            }
            page = view.currentPage.flatMap { document?.index(for: $0) }.map { $0 + 1 } ?? 1
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(layoutChanged), name: .PDFViewSelectionChanged, object: view)
            center.addObserver(self, selector: #selector(layoutChanged), name: .PDFViewScaleChanged, object: view)
            let clipView = view.documentView?.enclosingScrollView?.contentView
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: clipView)
            }
            observingPosition = true
            layoutChanged()
        }
    }

    @objc private func pageChanged() {
        if let current = view?.currentPage, let index = document?.index(for: current) { page = index + 1 }
        positionChanged()
    }

    @objc private func positionChanged() {
        layoutChanged()
        guard observingPosition, let view, let destination = view.currentDestination,
              let pdfPage = destination.page, let index = document?.index(for: pdfPage) else { return }
        let bounds = pdfPage.bounds(for: .cropBox)
        guard bounds.height > 0, bounds.width > 0 else { return }
        let point = destination.point
        let offset: CGFloat = switch pdfPage.rotation {
        case 90: (point.x - bounds.minX) / bounds.width
        case 180: (point.y - bounds.minY) / bounds.height
        case 270: (bounds.maxX - point.x) / bounds.width
        default: (bounds.maxY - point.y) / bounds.height
        }
        guard offset.isFinite else { return }
        rememberPosition(page: index + 1, offset: min(1, max(0, offset)))
    }

    private func rememberPosition(page: Int, offset: Double) {
        lastPosition = ReadingPosition(page: page, offset: offset, document_revision: revision,
                                       updated_at: Int(Date.now.timeIntervalSince1970 * 1000))
        positionTask?.cancel()
        positionTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(750)) }
            catch { return }
            self?.flushPosition()
        }
    }

    func flushPosition() {
        positionTask?.cancel()
        positionTask = nil
        if let lastPosition { onPosition?(lastPosition) }
    }

    func positionForRestart(thumbnails: Bool) -> RestartSnapshot.PDFPosition? {
        positionChanged()
        flushPosition()
        guard observingPosition, let revision, let view, let destination = view.currentDestination,
              let pdfPage = destination.page, let index = document?.index(for: pdfPage),
              destination.point.x.isFinite, destination.point.y.isFinite else { return nil }
        return .init(revision: revision, page: index + 1, point: destination.point,
                     scale: fitMode == nil ? view.scaleFactor : nil, thumbnails: thumbnails,
                     fitPage: fitMode == .page ? true : nil)
    }

    func go(to number: Int) {
        guard let document, let view else { return }
        let index = min(max(number, 1), document.pageCount) - 1
        if let page = document.page(at: index) {
            view.go(to: page)
            self.page = index + 1
            if observingPosition { rememberPosition(page: index + 1, offset: 0) }
        }
    }

    private func navigate(page: Int, offset: Double) {
        guard let view, let document, (1...document.pageCount).contains(page),
              let target = document.page(at: page - 1) else { return }
        let bounds = target.bounds(for: .cropBox)
        let point: CGPoint = switch target.rotation {
        case 90: CGPoint(x: bounds.minX + bounds.width * offset, y: bounds.minY)
        case 180: CGPoint(x: bounds.maxX, y: bounds.minY + bounds.height * offset)
        case 270: CGPoint(x: bounds.maxX - bounds.width * offset, y: bounds.maxY)
        default: CGPoint(x: bounds.minX, y: bounds.maxY - bounds.height * offset)
        }
        view.go(to: PDFDestination(page: target, at: point))
    }

    func hasSearch(for query: String) -> Bool {
        submittedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func search(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != submittedQuery, let document else { return }
        clearSearch()
        submittedQuery = text
        isSearching = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(foundMatch), name: .PDFDocumentDidFindMatch, object: document)
        center.addObserver(self, selector: #selector(finishedSearch), name: .PDFDocumentDidEndFind, object: document)
        document.beginFindString(text, withOptions: [.caseInsensitive])
    }

    func clearSearch() {
        if let document {
            stopObservingSearch(document)
            if isSearching { document.cancelFindString() }
        }
        isSearching = false
        submittedQuery = ""
        matches = []
        matchIndex = nil
        matchCount = 0
        matchBounds = []
    }

    private func stopObservingSearch(_ document: PDFDocument) {
        let center = NotificationCenter.default
        center.removeObserver(self, name: .PDFDocumentDidFindMatch, object: document)
        center.removeObserver(self, name: .PDFDocumentDidEndFind, object: document)
    }

    @objc private func foundMatch(_ notification: Notification) {
        guard isSearching, let match = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
        matches.append(match)
    }

    @objc private func finishedSearch() {
        guard isSearching, let document else { return }
        stopObservingSearch(document)
        isSearching = false
        matchCount = matches.count
        guard !matches.isEmpty else { return }
        let firstOnOrAfterPage = matches.firstIndex { match in
            match.pages.first.map { document.index(for: $0) >= page - 1 } == true
        }
        showMatch(firstOnOrAfterPage ?? 0)
    }

    func stepMatch(_ direction: Int) {
        guard let matchIndex, !matches.isEmpty else { return }
        showMatch((matchIndex + direction + matches.count) % matches.count)
    }

    private func showMatch(_ index: Int) {
        matchIndex = index
        view?.go(to: matches[index])
        layoutChanged()
    }

    func fit(_ mode: Fit) {
        fitMode = mode
        fitViewport = nil
        layoutChanged()
    }

    func actualSize() {
        guard let view else { return }
        fitMode = nil
        view.autoScales = false
        view.scaleFactor = 1
        layoutChanged()
    }

    func zoom(inward: Bool) {
        guard let view, inward ? view.canZoomIn : view.canZoomOut else { return }
        fitMode = nil
        view.autoScales = false
        if inward { view.zoomIn(nil) }
        else { view.zoomOut(nil) }
        layoutChanged()
    }

    private func applyFit(to view: PDFView) {
        let size = view.bounds.size
        guard let fitMode, fitViewport != size, size.width > 40, size.height > 40 else { return }
        if fitMode == .width {
            fitViewport = size
            view.autoScales = true
            return
        }
        guard let page = view.currentPage ?? document?.page(at: 0) else { return }
        let bounds = page.bounds(for: view.displayBox)
        let dimensions = page.rotation.isMultiple(of: 180) ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
        guard dimensions.width > 0, dimensions.height > 0 else { return }
        fitViewport = size
        view.autoScales = false
        let fitWidth = (size.width - view.pageBreakMargins.left - view.pageBreakMargins.right) / dimensions.width
        let fitHeight = (size.height - view.pageBreakMargins.top - view.pageBreakMargins.bottom) / dimensions.height
        let scale = min(fitWidth, fitHeight)
        view.scaleFactor = min(max(scale, view.minScaleFactor), view.maxScaleFactor)
    }

    @objc func layoutChanged() {
        guard observingPosition, geometryTask == nil else { return }
        geometryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { geometryTask = nil }
            guard let view else { return }
            applyFit(to: view)
            let title = switch fitMode {
            case .width: "Fit width"
            case .page: "Fit page"
            case nil: "\(Int((view.scaleFactor * 100).rounded()))%"
            }
            if zoomLabel != title { zoomLabel = title }
            let selection = view.currentSelection
            let anchor = selection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? visibleRects(for: selection, in: view).first : nil
            if selectionBounds != anchor { selectionBounds = anchor }
            let outlines = visibleRects(for: matchIndex.map { matches[$0] }, in: view)
            if matchBounds != outlines { matchBounds = outlines }
        }
    }

    private func visibleRects(for selection: PDFSelection?, in view: PDFView) -> [CGRect] {
        (selection?.selectionsByLine() ?? []).flatMap { line in
            line.pages.compactMap { page in
                let bounds = view.convert(line.bounds(for: page), from: page).intersection(view.bounds)
                guard !bounds.isEmpty else { return nil }
                return CGRect(x: bounds.minX - view.bounds.minX,
                              y: view.isFlipped ? bounds.minY - view.bounds.minY : view.bounds.maxY - bounds.maxY,
                              width: bounds.width, height: bounds.height)
            }
        }
    }

    func selectedText() -> (quote: String, anchor: Highlight.Anchor)? {
        guard let document, let selection = view?.currentSelection, let quote = selection.string,
              !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let quads: [Highlight.Anchor.Quad] = selection.selectionsByLine().flatMap { line in
            line.pages.compactMap { page in
                let bounds = page.bounds(for: .cropBox)
                let rect = line.bounds(for: page).intersection(bounds)
                guard !rect.isEmpty, bounds.width > 0, bounds.height > 0 else { return nil }
                let left = (rect.minX - bounds.minX) / bounds.width
                let right = (rect.maxX - bounds.minX) / bounds.width
                let top = (rect.maxY - bounds.minY) / bounds.height
                let bottom = (rect.minY - bounds.minY) / bounds.height
                return .init(page: document.index(for: page) + 1, points: [left, top, right, top, left, bottom, right, bottom])
            }
        }
        guard !quads.isEmpty else { return nil }
        return (String(quote.prefix(8000)), .init(kind: "pdf", quads: Array(quads.prefix(512)), document_revision: revision))
    }

    func showMarks(_ marks: [Highlight]) {
        let wanted = Set(marks.map(\.id))
        for id in Set(appliedMarks.keys).subtracting(wanted) {
            for (page, annotation) in appliedMarks.removeValue(forKey: id) ?? [] {
                page.removeAnnotation(annotation)
            }
        }
        for mark in marks where appliedMarks[mark.id] == nil {
            appliedMarks[mark.id] = locations(for: mark).map { page, rect, points in
                let annotation = PDFAnnotation(bounds: rect, forType: mark.style == .underline ? .underline : .highlight, withProperties: nil)
                annotation.quadrilateralPoints = points.map { NSValue(point: CGPoint(x: $0.x - rect.minX, y: $0.y - rect.minY)) }
                let storedColor = UInt32(mark.color.dropFirst(), radix: 16) ?? 0xffe873
                let hex: UInt32 = mark.style == .underline && storedColor == 0xffe873 ? 0xb18d22 : storedColor
                annotation.color = NSColor(srgbRed: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255,
                                           blue: Double(hex & 255) / 255, alpha: mark.style == .underline ? 1 : 0.5)
                page.addAnnotation(annotation)
                return (page, annotation)
            }
        }
        view?.needsDisplay = true
    }

    func jump(to highlight: Highlight?) {
        initialHighlight = highlight
        guard let highlight, let (page, rect, _) = locations(for: highlight).first else { return }
        view?.go(to: rect.insetBy(dx: -10, dy: -28), on: page)
    }

    private func locations(for mark: Highlight) -> [(PDFPage, CGRect, [CGPoint])] {
        guard let document,
              mark.anchor.document_revision == nil || mark.anchor.document_revision == revision else { return [] }
        return (mark.anchor.quads ?? []).compactMap { quad in
            guard quad.points.count == 8, (1...document.pageCount).contains(quad.page),
                  let page = document.page(at: quad.page - 1) else { return nil }
            let bounds = page.bounds(for: .cropBox)
            let points = stride(from: 0, to: 8, by: 2).map { index in
                CGPoint(x: bounds.minX + quad.points[index] * bounds.width,
                        y: bounds.minY + quad.points[index + 1] * bounds.height)
            }
            let rect = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            guard !rect.isEmpty else { return nil }
            return (page, rect, points)
        }
    }
}
