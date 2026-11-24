import AppKit
import SwiftUI

enum Shelf: Hashable, Codable {
    case rss, feed(String), category(String?), saved, pdfs, highlights, tag(String), starred, archive, trash

    var label: String {
        switch self {
        case .rss, .saved: "All articles"
        case .feed: "Subscription"
        case .category: "Uncategorized"
        case .pdfs: "PDFs"
        case .highlights: "Highlights"
        case .tag(let name): name
        case .starred: "Starred"
        case .archive: "Archive"
        case .trash: "Trash"
        }
    }
}

struct LibraryWindow: View {
    @FocusState private var articleListFocused: Bool
    private struct AddRequest: Identifiable {
        var file: URL? = nil
        let id = UUID()
    }

    private struct FeedRename: Identifiable {
        let feed: Feed
        var id: String { feed.id }
    }

    @Environment(BasketStore.self) private var store
    @Environment(InstalledAppUpdate.self) private var update
    @Environment(\.basketStyle) private var style
    @AppStorage("theme") private var theme = BasketTheme.system
    @BasketState private var showingServerStatus = false
    @BasketState private var readFilters: [Shelf: String] = [:]
    @AppStorage("showAllSidebarFeeds") private var showAllSidebarFeeds = false
    @BasketState private var shelf: Shelf? = .rss
    @BasketState private var selection: Set<String> = []
    @BasketState private var scrollTarget: String? = nil
    @BasketState private var columns: NavigationSplitViewVisibility = NavigationSplitViewVisibility.all
    @BasketState private var readerFocused = false
    @BasketState private var showSubscriptions: Bool = true
    @BasketState private var creatingFeedCategory = false
    @BasketState private var renamingFeedCategory: FeedCategory?
    @BasketState private var deletingFeedCategory: FeedCategory?
    @BasketState private var collapsedFeedCategories: Set<Shelf> = []
    @BasketState private var showSaved: Bool = true
    @BasketState private var feedRename: FeedRename? = nil
    @BasketState private var addRequest: AddRequest? = nil
    @BasketState private var highlightSelection: String? = nil
    @BasketState private var savedSelection: String? = nil
    @BasketState private var deletingPDF: Article? = nil
    @BasketState private var documentType: String = "All"
    @BasketState private var unsubscribingFeed: Feed? = nil
    @BasketState private var source: String = "All"
    @BasketState private var limit: Int = 100
    @BasketState private var highlightFilters = RestartSnapshot.HighlightFilters()
    @BasketState private var restartReader = RestartReaderState()
    @BasketState private var listPosition = RestartListPosition()
    @BasketState private var restartListTarget: String?
    @BasketState private var restoringShelf: Shelf?
    @BasketState private var restoredLibrary = false
    @BasketState private var focusedListTopID: String?
    @BasketState private var windowID = UUID()
    @BasketState private var openedImage: ArticleImage?
    @BasketState private var imageUsesWindow = false
    @BasketState private var restoreImageFocus: (() -> Void)?

    @BasketState private var showingSignIn = false
    @BasketState private var username = ""

    private var current: Shelf { shelf ?? .rss }
    private var readFilter: String { readFilters[current] ?? "Unread" }

    private func setReadFilter(_ value: String) {
        guard value != readFilter else { return }
        readFilters[current] = value
        if selection.count > 1 || selected.flatMap(store.article).map({ !matchesReadFilter($0) }) == true {
            selection = []
        }
    }
    private var selected: String? { selection.count == 1 ? selection.first : nil }
    private var hasSourceFilter: Bool { [.starred, .archive, .trash].contains(current) }
    private var feeds: [Feed] {
        store.library.feeds.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var tags: [String] {
        Set(store.library.articles.keys.compactMap(store.article).filter {
            $0.saved_at != nil && $0.location == "inbox"
        }.flatMap(\.tags)).sorted()
    }
    private var currentFeed: Feed? {
        if case .feed(let id) = current { return store.library.feeds[id] }
        return nil
    }

    private var currentCategoryName: String? {
        if case .category(let id?) = current { return store.library.feedCategories?[id]?.name }
        return nil
    }

    private func matchesReadFilter(_ article: Article) -> Bool {
        readFilter == "All" || article.read == (readFilter == "Read")
    }

    private var documentShelf: [Article] {
        store.library.articles.keys.compactMap(store.article).filter { article in
            let rss = article.feed_ids.contains { store.library.feeds[$0] != nil }
            let saved = article.saved_at != nil
            if hasSourceFilter {
                let matchesShelf = current == .starred ? article.isStarred && article.location != "trash"
                    : article.location == (current == .archive ? "archive" : "trash")
                return matchesShelf
            }
            guard article.location == "inbox" else { return false }
            switch current {
            case .rss: return rss
            case .feed(let id): return article.feed_ids.contains(id) && store.library.feeds[id] != nil
            case .category(let id):
                return article.feed_ids.contains { feedID in
                    store.library.feeds[feedID].map { $0.category_id == id } ?? false
                }
            case .saved: return saved && !article.isPDF
            case .pdfs: return saved && article.isPDF
            case .tag(let tag): return saved && article.tags.contains(tag)
            default: return false
            }
        }
    }

    private var hasMixedTypes: Bool { Set(documentShelf.map(\.isPDF)).count > 1 }

    private func filtered(_ documents: [Article], mixed: Bool) -> [Article] {
        documents.filter { article in
            if hasSourceFilter {
                if source == "Subscriptions" && !article.feed_ids.contains(where: { store.library.feeds[$0] != nil }) { return false }
                if source == "Read Later" && article.saved_at == nil { return false }
            } else if !selection.contains(article.id) && !matchesReadFilter(article) {
                return false
            }
            return !mixed || documentType == "All" || article.isPDF == (documentType == "PDFs")
        }.sorted { left, right in
            let saved: Bool
            switch current { case .saved, .pdfs, .tag: saved = true; default: saved = false }
            let a = saved ? left.saved_at ?? 0 : left.date.timeIntervalSince1970
            let b = saved ? right.saved_at ?? 0 : right.date.timeIntervalSince1970
            return a == b ? left.id < right.id : a > b
        }
    }

    var body: some View {
        libraryBody
            .onChange(of: store.feedCategories.map(\.id)) { _, ids in
                if case .category(let id?) = current, !ids.contains(id) { shelf = .rss }
            }
            .sheet(isPresented: $creatingFeedCategory) { FeedCategoryNameSheet() }
            .feedCategoryDialogs(renaming: $renamingFeedCategory, deleting: $deletingFeedCategory)
    }

    private var libraryBody: some View {
        let documents = documentShelf
        let mixed = Set(documents.map(\.isPDF)).count > 1
        let articles = filtered(documents, mixed: mixed)
        let displayed = articles.prefix(limit)
        let selectedArticles = displayed.filter { selection.contains($0.id) }
        let highlight = current == .highlights ? highlightSelection.flatMap { store.library.highlights?[$0] } : nil
        let article = current == .highlights ? highlight.flatMap { store.article($0.article_id) }
            : selectedArticles.count == 1 && selection.count == 1 ? selectedArticles.first : nil
        let reading = article.map {
            BasketStore.OpenArticle(id: $0.id, scope: store.updateScope, libraryID: store.library.libraryID)
        }
        return ZStack {
            if readerFocused, let article {
                reader(article, highlight: highlight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(style.color(style.readingSurface).ignoresSafeArea())
                    .modifier(BasketToastOverlay(location: .reader))
            } else {
                NavigationSplitView(columnVisibility: $columns) {
                    sidebar.navigationSplitViewColumnWidth(min: 155, ideal: 182, max: 250)
                } content: {
                    Group {
                        if current == .highlights {
                            HighlightsShelf(selection: $highlightSelection, filters: $highlightFilters,
                                            restartListTarget: $restartListTarget, listPosition: listPosition)
                        } else {
                            articleList(articles, selectedArticles: selectedArticles, mixed: mixed)
                        }
                    }
                        .navigationSplitViewColumnWidth(min: 230, ideal: 285, max: 380)
                } detail: {
                    Group {
                        if let article {
                            reader(article, highlight: highlight)
                        } else if store.profile == nil {
                            ContentUnavailableView {
                                Label("Open your library", systemImage: "person.crop.circle")
                            } actions: {
                                Button("Sign in…") { showingSignIn = true }
                                    .buttonStyle(BasketButton(primary: true))
                                    .disabled(!store.reachable)
                            }
                            .disabled(store.signingIn)
                        } else if selectedArticles.count > 1 {
                            BasketEmpty(title: "\(selectedArticles.count) articles selected", icon: "doc.on.doc")
                        } else {
                            BasketEmpty(title: current == .highlights ? "Select a highlight" : current == .pdfs ? "Select a PDF" : "Select an item",
                                        icon: current == .highlights ? "highlighter" : "doc.text")
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(style.color(style.readingSurface).ignoresSafeArea())
                    .modifier(BasketToastOverlay(location: .reader))
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .allowsHitTesting(openedImage == nil)
        .accessibilityHidden(openedImage != nil)
        .overlayPreferenceValue(ArticleImageReaderBounds.self) { anchor in
            if let openedImage {
                GeometryReader { geometry in
                    let window = CGRect(origin: .zero, size: geometry.size)
                    let bounds = imageUsesWindow ? window : anchor.map { geometry[$0] } ?? window
                    ArticleImageViewer(image: openedImage, expanded: imageUsesWindow, canExpand: !readerFocused,
                                       resize: { imageUsesWindow.toggle() }, close: closeArticleImage)
                        .frame(width: bounds.width, height: bounds.height)
                        .position(x: bounds.midX, y: bounds.midY)
                }
            }
        }
        .onExitCommand {
            if openedImage != nil { closeArticleImage() }
            else { clearDocumentSelection() }
        }
        .focusedSceneValue(\.selectedArticleActions, article.map { article in
            SelectedArticleActions(article: article, perform: { if openedImage == nil { perform($0, on: article) } })
        })
        .toolbar {
            if readerFocused || columns == .doubleColumn || columns == .detailOnly {
                if #available(macOS 26, *) {
                    ToolbarItem(placement: .primaryAction) { hiddenSidebarActions }
                        .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .primaryAction) { hiddenSidebarActions }
                }
            }
        }
        .toolbarBackground(.hidden, for: .windowToolbar)
        .dropDestination(for: URL.self) { urls, _ in
            guard openedImage == nil, addRequest == nil, let file = urls.first, file.isFileURL else { return false }
            addRequest = AddRequest(file: file)
            return true
        }
        .background {
            if store.canUndoArticleChange {
                ArticleUndoShortcut(undo: store.undoArticleChange)
            }
        }
        .modifier(LibraryRestartObserver(
            articleID: article?.id, libraryID: store.library.libraryID, didChangeLibrary: resetAfterLibraryChange,
            reader: restartReader, restore: restoreAfterRestart
        ))
        .onChange(of: shelf) {
            if let restoringShelf, shelf == restoringShelf {
                self.restoringShelf = nil
                return
            }
            restartListTarget = nil
            highlightSelection = nil
            highlightFilters = .init()
            documentType = "All"
            source = "All"
            limit = 100
            if let savedSelection { selectSavedItem(savedSelection) }
            else { selection = []; scrollTarget = nil }
            savedSelection = nil
        }
        .onChange(of: mixed) { if !mixed { documentType = "All" } }
        .onChange(of: displayed.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: article == nil) { if article == nil { readerFocused = false } }
        .onChange(of: reading, initial: true) {
            openedImage = nil
            restoreImageFocus = nil
            store.setOpenArticle(reading, in: windowID)
        }
        .onDisappear { store.setOpenArticle(nil, in: windowID) }
        .onChange(of: store.profile?.id) { shelf = .rss; selection = []; username = "" }
        .onChange(of: store.updateScope) {
            readFilters = [:]
            clearRestartTargets()
            feedRename = nil
            creatingFeedCategory = false
            renamingFeedCategory = nil
            deletingFeedCategory = nil
            collapsedFeedCategories = []
            addRequest = nil
            deletingPDF = nil
            savedSelection = nil
            highlightSelection = nil
            unsubscribingFeed = nil
            selection = []
            scrollTarget = nil
        }
        .alert("Sign in", isPresented: $showingSignIn) {
            TextField("Username", text: $username)
            Button("Sign in") { store.signIn(username) }
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Create account") { store.signIn(username, create: true) }
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter your username. Choose Create account to register a new one.")
        }
        .sheet(item: $feedRename) { RenameFeedSheet(feed: $0.feed) }
        .sheet(item: $addRequest) { request in
            AddSheet(initialFile: request.file, tags: tags, didSave: openSavedItem) { feed in
                showSubscriptions = true
                shelf = .feed(feed.id)
            }
        }
        .alert(item: $deletingPDF, content: deletePDFAlert)
        .confirmationDialog("Unsubscribe from \(unsubscribingFeed?.title ?? "this feed")?",
                            isPresented: Binding(get: { unsubscribingFeed != nil }, set: {
                                if !$0 { unsubscribingFeed = nil }
                            }), presenting: unsubscribingFeed) { feed in
            Button("Unsubscribe and Delete", role: .destructive) { Task { await store.unsubscribe(feed) } }
        } message: { _ in
            Text("Unstarred articles will be permanently deleted, including copies in Read Later, Archive, Trash, and other feeds. Starred articles will be kept.")
        }
    }

    private func deletePDFAlert(_ document: Article) -> Alert {
        let message = document.pdf?.source == "upload"
            ? "The PDF will be deleted from Cloudflare R2 and its highlights will be removed from your library."
            : "The saved link and its highlights will be removed from your library."
        return Alert(title: Text("Permanently delete PDF?"), message: Text(message),
                     primaryButton: .destructive(Text("Delete Permanently")) {
                         Task { await store.permanentlyDeletePDF(document) }
                     }, secondaryButton: .cancel())
    }

    private func showAdd() {
        addRequest = AddRequest()
    }

    private var hiddenSidebarActions: some View {
        HStack(spacing: BasketTokens.spacing / 2) {
            if update.isReady { AppUpdateChip(restart: restart) }
            LibraryAddButton(action: showAdd)
        }
    }

    private func openSavedItem(_ article: Article) {
        showSaved = true
        readerFocused = false
        let destination: Shelf = article.isPDF ? .pdfs : .saved
        if shelf == destination { selectSavedItem(article.id) }
        else {
            savedSelection = article.id
            shelf = destination
        }
    }

    private func selectSavedItem(_ id: String) {
        selection = [id]
        if let index = filtered(documentShelf, mixed: hasMixedTypes).firstIndex(where: { $0.id == id }) {
            limit = max(limit, index + 1)
        }
        scrollTarget = id
    }

    private func restart() async throws {
        let scope = store.updateScope
        let capture = restartReader.capture
        let selectedID = current == .highlights
            ? highlightSelection.flatMap { store.library.highlights?[$0]?.article_id }
            : selected
        var snapshot = RestartSnapshot(
            origin: store.origin, accountID: store.profile?.id, libraryID: store.library.libraryID,
            shelf: current, selection: selection, highlightID: highlightSelection,
            listTopID: readerFocused ? focusedListTopID : listPosition.topID,
            readStatus: readFilter, documentType: documentType, source: source, highlights: highlightFilters, listLimit: limit,
            columns: columns == .detailOnly ? .detail : columns == .doubleColumn ? .double : .all,
            readerFocused: readerFocused, showSubscriptions: showSubscriptions, showSaved: showSaved
        )
        if let capture, capture.id == selectedID { snapshot.reader = await capture.position() }
        guard scope == store.updateScope, snapshot.libraryID == store.library.libraryID else {
            throw CancellationError()
        }
        try update.restart(with: snapshot)
    }

    private func restoreAfterRestart() async {
        guard let snapshot = update.takeResume(), matchesRestartScope(snapshot) else { return }
        if store.library.libraryID == nil, snapshot.libraryID != nil {
            await store.refresh()
        }
        guard matchesRestartScope(snapshot), store.library.libraryID == snapshot.libraryID else { return }
        switch snapshot.shelf {
        case .feed(let id) where store.library.feeds[id] == nil: return
        case .category(let id?) where store.library.feedCategories?[id] == nil: return
        case .tag(let tag) where !tags.contains(tag): return
        default: break
        }

        restoredLibrary = true
        if shelf != snapshot.shelf { restoringShelf = snapshot.shelf }
        shelf = snapshot.shelf
        readFilters[snapshot.shelf] = snapshot.readStatus
        showSubscriptions = snapshot.showSubscriptions
        showSaved = snapshot.showSaved
        columns = switch snapshot.columns {
        case .all: .all
        case .double: .doubleColumn
        case .detail: .detailOnly
        }
        highlightFilters = snapshot.highlights
        let documents = documentShelf
        let mixed = Set(documents.map(\.isPDF)).count > 1
        documentType = mixed ? snapshot.documentType : "All"
        source = snapshot.source
        let available = Set(documents.map(\.id))
        selection = snapshot.selection.intersection(available)
        let ids = filtered(documents, mixed: mixed).map(\.id)
        selection.formIntersection(ids)
        let highlight = snapshot.highlightID.flatMap { store.library.highlights?[$0] }.flatMap { highlight -> Highlight? in
            guard let article = store.article(highlight.article_id), article.location != "trash" else { return nil }
            return highlight
        }
        highlightSelection = current == .highlights ? highlight?.id : nil
        let itemID = current == .highlights ? highlight?.article_id : selected
        restartReader.pending = snapshot.reader?.id == itemID ? snapshot.reader : nil
        if current == .highlights {
            restartListTarget = snapshot.listTopID ?? highlightSelection
        } else {
            let targets = selection.union(snapshot.listTopID.map { [$0] } ?? [])
            let lastIndex = ids.lastIndex { targets.contains($0) }.map { $0 + 1 } ?? 0
            limit = max(100, snapshot.listLimit, lastIndex)
            restartListTarget = snapshot.listTopID.flatMap { ids.contains($0) ? $0 : nil } ?? selected
        }
        readerFocused = snapshot.readerFocused && itemID != nil
        focusedListTopID = readerFocused ? restartListTarget : nil
    }

    private func matchesRestartScope(_ snapshot: RestartSnapshot) -> Bool {
        snapshot.origin == store.origin && snapshot.accountID == store.profile?.id
    }

    private func clearRestartTargets() {
        restoringShelf = nil
        restoredLibrary = false
        focusedListTopID = nil
        restartListTarget = nil
        restartReader.pending = nil
        restartReader.capture = nil
    }

    private func resetAfterLibraryChange() {
        guard restoredLibrary else { return }
        clearRestartTargets()
        shelf = .rss
        selection = []
        highlightSelection = nil
        readerFocused = false
    }

    private func reader(_ article: Article, highlight: Highlight?) -> some View {
        Group {
            if article.isPDF {
                PDFReader(article: article, highlight: highlight, tags: tags, isFocused: readerFocused,
                          focus: toggleReaderFocus, perform: { perform($0, on: article) },
                          delete: { deletingPDF = article }, leave: clearDocumentSelection,
                          restartReader: restartReader)
            } else {
                ArticleReader(article: article, highlight: highlight, isFocused: readerFocused, focus: toggleReaderFocus,
                              perform: { perform($0, on: article) }, showImage: openArticleImage,
                              restartReader: restartReader)
            }
        }
        .id("\(store.updateScope)-\(article.id)")
    }

    private func clearDocumentSelection() {
        if readerFocused { restartListTarget = focusedListTopID }
        readerFocused = false
        selection = []
        highlightSelection = nil
        scrollTarget = nil
        restartReader.pending = nil
        restartReader.capture = nil
        store.setOpenArticle(nil, in: windowID)
    }

    private func openArticleImage(_ image: ArticleImage, restoreFocus: @escaping () -> Void) {
        imageUsesWindow = false
        restoreImageFocus = restoreFocus
        openedImage = image
    }

    private func closeArticleImage() {
        openedImage = nil
        let restore = restoreImageFocus
        restoreImageFocus = nil
        Task { @MainActor in
            await Task.yield()
            if openedImage == nil { restore?() }
        }
    }

    private func toggleReaderFocus() {
        if readerFocused {
            restartListTarget = focusedListTopID
        } else {
            focusedListTopID = listPosition.topID
        }
        readerFocused.toggle()
    }

    private var feedsWithUnreadArticles: Set<String> {
        let pendingArticleIDs = Set(store.library.pending.map(\.articleID))
        var feedIDs = Set<String>()
        for cached in store.library.articles.values where !cached.feed_ids.isEmpty {
            let article = pendingArticleIDs.contains(cached.id) ? store.article(cached.id) ?? cached : cached
            if article.location == "inbox" && !article.read {
                feedIDs.formUnion(article.feed_ids)
            }
        }
        return feedIDs
    }

    private var sidebar: some View {
        let unreadFeedIDs = showSubscriptions ? feedsWithUnreadArticles : []
        let unreadSavedShelves = showSaved ? savedShelvesWithUnreadArticles : []
        let subscriptions = showSubscriptions ? feeds : []
        let visibleFeeds = showAllSidebarFeeds ? subscriptions : subscriptions.filter { feed in
            unreadFeedIDs.contains(feed.id) || shelf == .feed(feed.id)
        }
        return List(selection: $shelf) {
            sidebarHeader {
                HStack {
                    disclosure("Subscriptions", expanded: $showSubscriptions)
                    Spacer()
                    Button {
                        creatingFeedCategory = true
                    } label: {
                        Label("New Category", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!store.canUseAPI)
                    .help("New Category")
                }
            }
            if showSubscriptions {
                Label("All articles", systemImage: "dot.radiowaves.left.and.right").tag(Shelf.rss).basketSelection(shelf == .rss)
                let categories = store.feedCategories
                if categories.isEmpty {
                    ForEach(visibleFeeds) { sidebarFeed($0, unread: unreadFeedIDs, nested: false) }
                } else {
                    ForEach(categories) { category in
                        sidebarCategory(category.name, id: category.id, feeds: visibleFeeds, unread: unreadFeedIDs)
                    }
                    sidebarCategory("Uncategorized", id: nil, feeds: visibleFeeds, unread: unreadFeedIDs)
                }
                if !subscriptions.isEmpty {
                    Button {
                        showAllSidebarFeeds.toggle()
                    } label: {
                        Text(showAllSidebarFeeds ? "Show unread feeds" : "Show all feeds")
                            .font(.system(size: BasketTokens.labelSize))
                            .foregroundStyle(style.accent)
                            .padding(.leading, 20)
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .selectionDisabled()
                    .listRowSeparator(.hidden)
                }
            }
            sidebarSectionDivider
            sidebarHeader { disclosure("Read Later", expanded: $showSaved) }
            if showSaved {
                sidebarSavedShelf("All articles", systemImage: "bookmark", destination: .saved, unread: unreadSavedShelves)
                sidebarSavedShelf("PDFs", systemImage: "doc.richtext", destination: .pdfs, unread: unreadSavedShelves)
                ForEach(tags, id: \.self) { tag in
                    sidebarSavedShelf(tag, systemImage: "tag", destination: .tag(tag), unread: unreadSavedShelves)
                }
            }
            sidebarSectionDivider
            sidebarHeader { Text("Library").fontWeight(.semibold) }
            Label("Highlights", systemImage: "highlighter").tag(Shelf.highlights).basketSelection(shelf == .highlights)
            Label("Starred", systemImage: "star").tag(Shelf.starred).basketSelection(shelf == .starred)
            Label("Archive", systemImage: "archivebox").tag(Shelf.archive).basketSelection(shelf == .archive)
            Label("Trash", systemImage: "trash").tag(Shelf.trash).basketSelection(shelf == .trash)
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(style.color(style.palette.sidebar))
        .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            HStack(spacing: BasketTokens.spacing / 2) {
                FeedBasketWordmark(compact: update.isReady)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if update.isReady {
                    AppUpdateChip(restart: restart)
                }
            }
            .padding(.horizontal, update.isReady ? BasketTokens.spacing : BasketTokens.spacing * 1.5)
            .padding(.vertical, BasketTokens.spacing)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                LibraryAddFooter(action: showAdd)
                sidebarFooter
            }
        }
    }

    private var savedShelvesWithUnreadArticles: Set<Shelf> {
        let pendingArticleIDs = Set(store.library.pending.map(\.articleID))
        var shelves = Set<Shelf>()
        for cached in store.library.articles.values {
            let article = pendingArticleIDs.contains(cached.id) ? store.article(cached.id) ?? cached : cached
            guard article.saved_at != nil, article.location == "inbox", !article.read else { continue }
            shelves.insert(article.isPDF ? .pdfs : .saved)
            shelves.formUnion(article.tags.map { .tag($0) })
        }
        return shelves
    }

    private func sidebarSavedShelf(_ title: String, systemImage: String, destination: Shelf, unread: Set<Shelf>) -> some View {
        Button { shelf = destination } label: {
            SidebarUnreadLabel(title: title, systemImage: systemImage,
                               selected: shelf == destination, hasUnread: unread.contains(destination))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(shelf == destination ? .isSelected : [])
        .tag(destination)
        .basketSelection(shelf == destination)
    }

    private func sidebarFeed(_ feed: Feed, unread: Set<String>, nested: Bool) -> some View {
        let destination = Shelf.feed(feed.id)
        let drag = store.canUseAPI && !store.feedCategories.isEmpty
            ? FeedSidebarDrag(kind: .feed, id: feed.id, scope: store.updateScope) : nil
        return SidebarFeedRow(feed: feed, selected: shelf == destination, hasUnread: unread.contains(feed.id),
                       drag: drag, activate: { shelf = destination },
                       rename: { feedRename = FeedRename(feed: feed) }, unsubscribe: { unsubscribingFeed = feed })
            .padding(.leading, nested ? 16 : 0)
            .tag(destination)
            .basketSelection(shelf == destination)
    }

    @ViewBuilder private func sidebarCategory(_ title: String, id: String?, feeds: [Feed], unread: Set<String>) -> some View {
        let group = Shelf.category(id)
        let collapsed = collapsedFeedCategories.contains(group)
        let children = feeds.filter { $0.category_id == id }
        let category = id.flatMap { store.library.feedCategories?[$0] }
        SidebarRowWithActions(menuTitle: "Category actions for " + title, showsActions: category != nil) {
            HStack(spacing: 5) {
                Button {
                    if collapsed { collapsedFeedCategories.remove(group) }
                    else { collapsedFeedCategories.insert(group) }
                } label: {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 16, height: 20)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(collapsed ? "Expand " + title : "Collapse " + title)
                Button {
                    shelf = group
                } label: {
                    Label(title, systemImage: "folder")
                        .fontWeight(children.contains { unread.contains($0.id) } ? .semibold : .regular)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shelf == group ? .isSelected : [])
                .feedSidebarDraggable(category.flatMap { category in
                    store.canUseAPI ? FeedSidebarDrag(kind: .category, id: category.id, scope: store.updateScope) : nil
                })
            }
        } actions: {
            if let category { categoryActions(category) }
        }
        .feedCategoryDropTarget(id)
        .tag(group)
        .basketSelection(shelf == group)
        if !collapsed || children.contains(where: { shelf == .feed($0.id) }) {
            ForEach(children) { sidebarFeed($0, unread: unread, nested: true) }
        }
    }

    private func categoryActions(_ category: FeedCategory) -> some View {
        FeedCategoryActions(category: category, rename: { renamingFeedCategory = category },
                            delete: { deletingFeedCategory = category })
    }

    private var sidebarSectionDivider: some View {
        Rectangle()
            .fill(style.color(BasketTokens.line))
            .frame(height: 1)
            .padding(.vertical, 6)
            .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityHidden(true)
    }

    private var sidebarFooter: some View {
        let status = BasketStatus(online: store.reachable)
        let nextTheme: BasketTheme = style.scheme == .dark ? .light : .dark
        let themeAction = nextTheme == .light ? "Switch to Light Mode" : "Switch to Dark Mode"
        return VStack(spacing: 0) {
            Rectangle().fill(style.color(BasketTokens.line)).frame(height: 1).accessibilityHidden(true)
            HStack(spacing: 6) {
                Button {
                    theme = nextTheme
                } label: {
                    Label(themeAction, systemImage: nextTheme == .light ? "sun.max" : "moon")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(themeAction)

                profileMenu
                Button {
                    showingServerStatus.toggle()
                } label: {
                    status.dot
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                        .overlay(alignment: .topTrailing) {
                            if store.syncIssue != nil || !store.library.pending.isEmpty {
                                Image(systemName: store.syncIssue == nil ? "clock.fill" : "exclamationmark.circle.fill")
                                    .font(.system(size: 10)).foregroundStyle(style.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(syncStatusLabel(status.title))
                .help(syncStatusLabel(status.title))
                .popover(isPresented: $showingServerStatus, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: BasketTokens.spacing) {
                        status
                        if !store.library.pending.isEmpty {
                            Text("\(store.library.pending.count) changes waiting to sync")
                        }
                        if let issue = store.syncIssue { Text(issue) }
                        Button("Sync now", systemImage: "arrow.clockwise") {
                            showingServerStatus = false
                            Task { await store.refreshManually() }
                        }
                        .buttonStyle(BasketButton())
                    }
                    .padding(BasketTokens.spacing * 1.5)
                    .frame(maxWidth: 280, alignment: .leading)
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, BasketTokens.spacing)
            .padding(.vertical, 5)
        }
        .background(.bar)
    }

    private func syncStatusLabel(_ title: String) -> String {
        if let issue = store.syncIssue { return "\(title). \(issue)" }
        if !store.library.pending.isEmpty { return "\(title). \(store.library.pending.count) changes waiting to sync." }
        return title
    }

    private func sidebarHeader<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .font(.system(size: BasketTokens.labelSize))
            .accessibilityAddTraits(.isHeader)
            .selectionDisabled()
            .listRowSeparator(.hidden)
    }

    private func disclosure(_ title: String, expanded: Binding<Bool>) -> some View {
        Button {
            expanded.wrappedValue.toggle()
        } label: {
            Label(title, systemImage: expanded.wrappedValue ? "chevron.down" : "chevron.right")
        }.buttonStyle(.plain)
    }

    private func articleList(_ articles: [Article], selectedArticles: [Article], mixed: Bool) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            LibraryPaneHeader(horizontalInset: BasketTokens.spacing * 1.4) {
                HStack {
                    Text(currentFeed?.title ?? currentCategoryName ?? current.label)
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: BasketTokens.spacing)
                    if let feed = currentFeed {
                        FeedMenu(feed: feed, rename: { feedRename = FeedRename(feed: feed) },
                                 unsubscribe: { unsubscribingFeed = feed })
                            .id(feed.id)
                    }
                    LibraryFilter(groups: (mixed ? [
                        .init(title: "Type", options: ["All", "Articles", "PDFs"],
                              selection: $documentType, firstOptionLabel: "All types"),
                    ] : []) + (hasSourceFilter ? [
                        .init(title: "Source", options: ["All", "Subscriptions", "Read Later"], selection: $source),
                    ] : [
                        .init(title: "Read status", options: ["All", "Unread", "Read"],
                              selection: Binding(get: { readFilter }, set: setReadFilter)),
                    ]))
                }
            }
            if selectedArticles.count > 1 {
                ArticleBatchBar(articles: selectedArticles, clear: { selection = [] }) { action in
                    performBatch(action, on: selectedArticles)
                }
                Divider()
            }
            if articles.isEmpty {
                if let feed = currentFeed {
                    emptyFeed(feed)
                } else if !hasSourceFilter && readFilter != "All" {
                    emptyReadFilter
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    BasketEmpty(title: current == .pdfs ? "No PDFs" : "No items", icon: "tray")
                }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(articles.prefix(limit)) { article in
                            ArticleRow(article: article, archive: hasSourceFilter, selected: selection.contains(article.id),
                                       keyboardFocused: articleListFocused && selected == article.id,
                                       perform: { performRowAction($0, on: article) })
                                .trackRestartRow(article.id, in: listPosition)
                                .tag(article.id)
                                .basketSelection(selection.contains(article.id))
                        }
                        if articles.count > limit {
                            Button("Show more") { limit += 100 }.buttonStyle(BasketButton()).selectionDisabled()
                        } else if let feed = currentFeed, feed.error != nil || (!feed.isWebsite && feed.initial_done) {
                            FeedHistoryFooter(feed: feed).id(feed.id)
                                .padding(.vertical, BasketTokens.spacing)
                                .selectionDisabled()
                        }
                    }
                    .listStyle(.plain)
                    .focused($articleListFocused)
                    .trackRestartViewport(in: listPosition)
                    .scrollContentBackground(.hidden)
                    .contextMenu(forSelectionType: String.self) { ids in
                        let targets = articles.prefix(limit).filter { ids.contains($0.id) }
                        if targets.count == 1, let article = targets.first {
                            if article.isPDF && article.location == "trash" {
                                Button("Delete Permanently…", role: .destructive) { deletingPDF = article }
                                    .disabled(!store.canUseAPI || article.pdf?.deletion_pending == true)
                            }
                            ForEach(ArticleRowAction.allCases.filter { $0.allows(article) }, id: \.self) { action in
                                Button(action.title(for: article)) { performRowAction(action, on: article) }
                            }
                            if article.location == "trash" && !article.isPDF {
                                Button("Restore to Inbox") { store.restoreToInbox(article.id) }
                            } else if ArticleAction.trash.allows(article) {
                                Button("Move to Trash", role: .destructive) { perform(.trash, on: article) }
                            }
                        } else if targets.count > 1 {
                            ForEach(ArticleBatchAction.allCases, id: \.self) { action in
                                Button(action.title, role: action == .trash ? .destructive : nil) {
                                    performBatch(action, on: targets)
                                }
                                .disabled(!targets.contains(where: action.allows))
                            }
                        }
                    }
                    .task(id: restartListTarget) { [target = restartListTarget] in
                        guard let target else { return }
                        await Task.yield()
                        guard !Task.isCancelled, restartListTarget == target else { return }
                        proxy.scrollTo(target, anchor: .top)
                        restartListTarget = nil
                    }
                    .task(id: scrollTarget) { [target = scrollTarget] in
                        guard let target else { return }
                        await Task.yield()
                        guard !Task.isCancelled, scrollTarget == target else { return }
                        if selected == target { proxy.scrollTo(target) }
                        scrollTarget = nil
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.color(style.readingSurface).ignoresSafeArea())
        .modifier(BasketToastOverlay(location: .articleList))
    }

    private var emptyReadFilter: some View {
        VStack(spacing: BasketTokens.spacing) {
            let noun = current == .pdfs ? "PDFs" : "items"
            Text(readFilter == "All" ? "No \(noun)" : "No \(readFilter.lowercased()) \(noun)")
                .font(.headline)
            if readFilter != "All" {
                Button("Show all") { setReadFilter("All") }.buttonStyle(.link)
            }
        }
    }

    private func emptyFeed(_ feed: Feed) -> some View {
        VStack(spacing: BasketTokens.spacing) {
            if !feed.initial_done && feed.error == nil && store.canUseAPI {
                ProgressView("Fetching articles…").controlSize(.small)
            } else {
                emptyReadFilter
                FeedHistoryFooter(feed: feed).id(feed.id)
            }
        }
        .padding(BasketTokens.spacing * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func performRowAction(_ action: ArticleRowAction, on article: Article) {
        guard let latest = store.article(article.id), action.allows(latest) else { return }
        if let articleAction = action.articleAction {
            perform(articleAction, on: latest)
        } else {
            store.change(Mutation(articleID: latest.id, read: !latest.read))
        }
    }

    private func perform(_ action: ArticleAction, on article: Article) {
        guard let latest = store.article(article.id), action.allows(latest) else { return }
        switch action {
        case .star:
            store.change(Mutation(articleID: latest.id, starred: !latest.isStarred))
        case .archive, .trash:
            let articles = selected == latest.id ? filtered(documentShelf, mixed: hasMixedTypes) : []
            let nextIndex = articles.firstIndex { $0.id == latest.id }.map { $0 + 1 }
            let mutation = Mutation(articleID: latest.id, action: action == .archive ? "archive" : "trash")
            guard store.change(mutation), let nextIndex else { return }

            if articles.indices.contains(nextIndex) {
                limit = max(limit, nextIndex + 1)
                let next = articles[nextIndex].id
                selection = [next]
                scrollTarget = next
            } else {
                selection = []
                scrollTarget = nil
            }
        }
    }

    private func performBatch(_ action: ArticleBatchAction, on articles: [Article]) {
        if store.changeArticles(articles.map(\.id), action: action) {
            selection = []
            scrollTarget = nil
        }
    }

    private var profileMenu: some View {
        Menu {
            if let profile = store.profile {
                Text(profile.username ?? (profile.name.isEmpty ? profile.email : profile.name))
                if !profile.email.isEmpty { Text(profile.email) }
                Button("Sign out") { Task { await store.signOut() } }
            }
            if !store.signingIn && (store.profile == nil || !store.authenticated) {
                Button("Sign in…") { showingSignIn = true }.disabled(!store.reachable)
            }
        } label: {
            Group {
                if let picture = store.profile?.picture, let url = URL(string: picture), url.scheme == "https", store.reachable {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() }
                        placeholder: { Image(systemName: "person.crop.circle") }
                        .frame(width: 22, height: 22).clipShape(Circle())
                } else { Image(systemName: "person.crop.circle") }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Account")
        .help("Account")
    }
}

private struct LibraryRestartObserver: ViewModifier {
    let articleID: String?
    let libraryID: String?
    let didChangeLibrary: () -> Void
    let reader: RestartReaderState
    let restore: () async -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: libraryID) { previous, _ in
                if previous != nil { didChangeLibrary() }
            }
            .onChange(of: articleID) { _, id in
                if reader.pending?.id != id { reader.pending = nil }
            }
            .task { await restore() }
    }
}
