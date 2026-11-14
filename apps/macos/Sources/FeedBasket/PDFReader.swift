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

    @BasketState private var reader = PDFReaderController()
    @BasketState private var thumbnails = true
    @BasketState private var editingTags = false
    @BasketState private var tagText = ""
    @BasketState private var query = ""
    @BasketState private var pageEntry = "1"
    @BasketState private var error: String?
    @BasketState private var retry = 0
    @BasketState private var savingMark = false
    @BasketState private var password = ""
    @BasketState private var lockedPDF: LockedPDF?

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
        .onChange(of: reader.page) { pageEntry = String(reader.page) }
        .onChange(of: highlight?.id) { reader.jump(to: highlight) }
        .onChange(of: marks.map(\.id)) { reader.showMarks(marks) }
        .onDisappear { reader.flushPosition() }
        .popover(isPresented: $editingTags) {
            VStack(alignment: .leading, spacing: BasketTokens.spacing) {
                Text("Edit tags").font(.headline)
                LibraryTagField(suggestions: tags, text: $tagText)
                Button("Save") {
                    do {
                        let updatedTags = try LibraryTags.parse(tagText)
                        if store.change(Mutation(articleID: article.id, tags: updatedTags)) { editingTags = false }
                    } catch { store.report(error) }
                }.buttonStyle(BasketButton(primary: true))
            }.padding(14).frame(width: 300)
        }
    }

    @ViewBuilder private var readerContent: some View {
        if article.pdf?.deletion_pending == true {
            BasketEmpty(title: "Deleting PDF…", icon: "trash")
        } else if let document = reader.document {
            HStack(spacing: 0) {
                if thumbnails { thumbnailRail(document); Divider() }
                PDFCanvas(reader: reader, canMark: article.location != "trash" && store.canUseAPI, mark: save)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(article.title).font(.headline).lineLimit(1).help(article.title)
                Spacer()
                if article.location != "trash", article.pdf?.deletion_pending != true {
                    Button { tagText = article.tags.joined(separator: ", "); editingTags = true } label: {
                        Label("Edit tags", systemImage: "tag").labelStyle(.iconOnly)
                    }.help("Edit tags")
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
                        Button("Move to Trash", role: .destructive) { perform(.dislike) }
                        if article.pdf?.source == "link", let url = article.original {
                            Button("Open original") { NSWorkspace.shared.open(url) }
                        }
                    } label: {
                        Label("PDF actions", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                if article.location == "trash" && article.pdf?.deletion_pending != true {
                    Button("Restore") { store.change(Mutation(articleID: article.id, action: "restore")) }
                    Button("Delete Permanently…", role: .destructive, action: delete).disabled(!store.canUseAPI)
                }
                toolbarButton(isFocused ? "Exit Focus Mode" : "Enter Focus Mode",
                              icon: isFocused ? "arrow.down.right.and.arrow.up.left" : "viewfinder", action: focus)
            }
            if let document = reader.document, article.pdf?.deletion_pending != true {
                HStack(spacing: 7) {
                    toolbarButton("Thumbnails", icon: thumbnails ? "sidebar.left" : "rectangle") { thumbnails.toggle() }
                    toolbarButton("Previous page", icon: "chevron.left") { reader.go(to: reader.page - 1) }
                        .disabled(reader.page <= 1)
                    TextField("Page", text: $pageEntry)
                        .frame(width: 37)
                        .onSubmit {
                            if let page = Int(pageEntry) { reader.go(to: page) }
                            pageEntry = String(reader.page)
                        }
                    Text("/ \(document.pageCount)").foregroundStyle(.secondary).monospacedDigit()
                    toolbarButton("Next page", icon: "chevron.right") { reader.go(to: reader.page + 1) }
                        .disabled(reader.page >= document.pageCount)
                    Divider().frame(height: 15)
                    toolbarButton("Zoom out", icon: "minus.magnifyingglass") { reader.view?.zoomOut(nil) }
                    toolbarButton("Zoom in", icon: "plus.magnifyingglass") { reader.view?.zoomIn(nil) }
                    toolbarButton("Fit page", icon: "arrow.up.left.and.arrow.down.right") { reader.view?.autoScales = true }
                    Spacer(minLength: 2)
                    TextField("Find in PDF", text: $query)
                        .frame(minWidth: 70, maxWidth: 140)
                        .onSubmit { reader.find(query) }
                    toolbarButton("Find next", icon: "magnifyingglass") { reader.find(query) }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if reader.canMark && article.location != "trash" {
                    HStack(spacing: 7) {
                        ForEach([Highlight.Mark.highlight, .underline], id: \.self) { mark in
                            Button { save(mark) } label: { Label(mark.label, systemImage: mark.icon) }
                                .buttonStyle(BasketButton())
                                .disabled(!store.canUseAPI || savingMark)
                        }
                    }
                }
            }
            if !article.tags.isEmpty { TagLabel(tag: article.tags.joined(separator: " · ")) }
        }
        .padding(.horizontal, BasketTokens.spacing)
        .padding(.vertical, 7)
        .buttonStyle(.borderless)
    }

    private func toolbarButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(title, systemImage: icon).labelStyle(.iconOnly) }.help(title)
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
        reader.open(document, revision: revision, position: store.readingPosition(for: article),
                    highlight: highlight, marks: marks) { position in
            store.rememberPDFPosition(position, articleID: article.id, scope: scope)
        }
    }

    private func save(_ mark: Highlight.Mark) {
        guard let selection = reader.selectedText(), !savingMark else { return }
        savingMark = true
        error = nil
        Task {
            defer { savingMark = false }
            do {
                try await store.saveHighlight(article: article, mark: mark, quote: selection.quote, anchor: selection.anchor)
                reader.view?.clearSelection()
            } catch {
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
}

private struct PDFCanvas: NSViewRepresentable {
    let reader: PDFReaderController
    let canMark: Bool
    let mark: (Highlight.Mark) -> Void

    func makeNSView(context: Context) -> AnnotatablePDFView {
        let view = AnnotatablePDFView()
        view.displayMode = .singlePageContinuous
        view.displayBox = .cropBox
        view.autoScales = true
        reader.attach(view)
        return view
    }

    func updateNSView(_ view: AnnotatablePDFView, context: Context) { view.mark = canMark ? mark : nil }
}

private final class AnnotatablePDFView: PDFView {
    var mark: ((Highlight.Mark) -> Void)?

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
private final class PDFReaderController: NSObject {
    private(set) var document: PDFDocument?
    private(set) var page = 1
    private(set) var canMark = false
    @ObservationIgnored private(set) weak var view: PDFView?
    @ObservationIgnored private var revision: String?
    @ObservationIgnored private var initialPosition: ReadingPosition?
    @ObservationIgnored private var initialHighlight: Highlight?
    @ObservationIgnored private var onPosition: ((ReadingPosition) -> Void)?
    @ObservationIgnored private var appliedMarks: [String: [(PDFPage, PDFAnnotation)]] = [:]
    @ObservationIgnored private var lastPosition: ReadingPosition?
    @ObservationIgnored private var positionTask: Task<Void, Never>?
    @ObservationIgnored private var observingPosition = false
    @ObservationIgnored private var findText = ""
    @ObservationIgnored private var matches: [PDFSelection] = []
    @ObservationIgnored private var matchIndex = -1

    func open(_ document: PDFDocument, revision: String, position: ReadingPosition?, highlight: Highlight?,
              marks: [Highlight], onPosition: @escaping (ReadingPosition) -> Void) {
        self.revision = revision
        initialPosition = position?.document_revision == nil || position?.document_revision == revision ? position : nil
        initialHighlight = highlight
        self.onPosition = onPosition
        self.document = document
        showMarks(marks)
    }

    func attach(_ view: PDFView) {
        flushPosition()
        NotificationCenter.default.removeObserver(self)
        self.view = view
        view.document = document
        observingPosition = false
        Task { @MainActor [weak self, weak view] in
            guard let self, let view, self.view === view else { return }
            view.layoutSubtreeIfNeeded()
            if let highlight = initialHighlight { jump(to: highlight) }
            else if let pos = lastPosition ?? initialPosition { navigate(page: pos.page, offset: pos.offset) }
            page = view.currentPage.flatMap { document?.index(for: $0) }.map { $0 + 1 } ?? 1
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(pageChanged), name: .PDFViewPageChanged, object: view)
            center.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: view)
            let clipView = view.documentView?.enclosingScrollView?.contentView
            if let clipView {
                clipView.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(positionChanged), name: NSView.boundsDidChangeNotification, object: clipView)
            }
            observingPosition = true
        }
    }

    @objc private func pageChanged() {
        if let current = view?.currentPage, let index = document?.index(for: current) { page = index + 1 }
        positionChanged()
    }

    @objc private func selectionChanged() {
        canMark = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @objc private func positionChanged() {
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

    func find(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let document, let view else { return }
        if text != findText {
            findText = text
            matches = document.findString(text, withOptions: [.caseInsensitive])
            matchIndex = -1
        }
        guard !matches.isEmpty else { NSSound.beep(); return }
        matchIndex = (matchIndex + 1) % matches.count
        let match = matches[matchIndex]
        view.setCurrentSelection(match, animate: true)
        view.go(to: match)
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
                let hex = UInt32(mark.color.dropFirst(), radix: 16) ?? 0xffe873
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
