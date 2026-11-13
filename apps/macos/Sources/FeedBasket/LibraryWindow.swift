import AppKit
import SwiftUI

enum Shelf: Hashable {
    case rss, feed(String), saved, tag(String), starred, archive, trash

    var label: String {
        switch self {
        case .rss, .saved: "All articles"
        case .feed: "Subscription"
        case .tag(let name): name
        case .starred: "Starred"
        case .archive: "Archive"
        case .trash: "Trash"
        }
    }
}

struct LibraryWindow: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    @AppStorage("theme") private var theme = BasketTheme.system
    @BasketState private var showingServerStatus = false
    @AppStorage("readStatusFilter") private var readFilter = "All"
    @AppStorage("showAllSidebarFeeds") private var showAllSidebarFeeds = false
    @BasketState private var shelf: Shelf? = .rss
    @BasketState private var selection: Set<String> = []
    @BasketState private var scrollTarget: String? = nil
    @BasketState private var columns: NavigationSplitViewVisibility = NavigationSplitViewVisibility.all
    @BasketState private var showSubscriptions: Bool = true
    @BasketState private var showSaved: Bool = true
    @BasketState private var addingFeed: Bool = false
    @BasketState private var source: String = "All"
    @BasketState private var limit: Int = 100

    @BasketState private var showingSignIn = false
    @BasketState private var username = ""

    private var current: Shelf { shelf ?? .rss }
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

    private func matchesReadFilter(_ article: Article) -> Bool {
        readFilter == "All" || article.read == (readFilter == "Read")
    }

    private var visible: [Article] {
        store.library.articles.keys.compactMap(store.article).filter { article in
            let rss = article.feed_ids.contains { store.library.feeds[$0] != nil }
            let saved = article.saved_at != nil
            if hasSourceFilter {
                let matchesShelf = current == .starred ? article.isStarred && article.location != "trash"
                    : article.location == (current == .archive ? "archive" : "trash")
                return matchesShelf && (source == "All" || (source == "Subscriptions" && rss) || (source == "Read Later" && saved))
            }
            // Keep selected articles visible if auto-read or sync changes their read status.
            guard article.location == "inbox",
                  selection.contains(article.id) || matchesReadFilter(article) else { return false }
            switch current {
            case .rss: return rss
            case .feed(let id): return article.feed_ids.contains(id) && store.library.feeds[id] != nil
            case .saved: return saved
            case .tag(let tag): return saved && article.tags.contains(tag)
            default: return false
            }
        }.sorted { left, right in
            let saved: Bool
            switch current { case .saved, .tag: saved = true; default: saved = false }
            let a = saved ? left.saved_at ?? 0 : left.date.timeIntervalSince1970
            let b = saved ? right.saved_at ?? 0 : right.date.timeIntervalSince1970
            return a == b ? left.id < right.id : a > b
        }
    }

    var body: some View {
        let articles = visible
        let displayed = articles.prefix(limit)
        let selectedArticles = displayed.filter { selection.contains($0.id) }
        let article = selectedArticles.count == 1 && selection.count == 1 ? selectedArticles.first : nil
        NavigationSplitView(columnVisibility: $columns) {
            sidebar.navigationSplitViewColumnWidth(min: 155, ideal: 182, max: 250)
        } content: {
            articleList(articles, selectedArticles: selectedArticles)
                .navigationSplitViewColumnWidth(min: 230, ideal: 285, max: 380)
        } detail: {
            Group {
                if let article {
                    ArticleReader(article: article, focus: { columns = columns == .detailOnly ? .all : .detailOnly },
                                  perform: { perform($0, on: article) })
                        .id("\(store.updateScope)-\(article.id)")
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
                    BasketEmpty(title: "Select an article", icon: "doc.text")
                }
            }
            .modifier(BasketToastOverlay(location: .reader))
        }
        .focusedSceneValue(\.selectedArticleActions, article.map { article in
            SelectedArticleActions(article: article, perform: { perform($0, on: article) })
        })
        .navigationSplitViewStyle(.balanced)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .background {
            if store.canUndoArticleChange {
                ArticleUndoShortcut(undo: store.undoArticleChange)
            }
        }
        .onChange(of: shelf) { selection = []; scrollTarget = nil; source = "All"; limit = 100 }
        .onChange(of: readFilter) {
            if selection.count > 1 || article.map({ !matchesReadFilter($0) }) == true { selection = [] }
        }
        .onChange(of: displayed.map(\.id)) { _, ids in selection.formIntersection(ids) }
        .onChange(of: store.profile?.id) { shelf = .rss; selection = []; username = "" }
        .onChange(of: store.updateScope) { addingFeed = false; selection = []; scrollTarget = nil }
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
        .sheet(isPresented: $addingFeed) {
            SubscriptionSheet { feed in
                showSubscriptions = true
                shelf = .feed(feed.id)
            }
        }
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
        let subscriptions = showSubscriptions ? feeds : []
        let visibleFeeds = showAllSidebarFeeds ? subscriptions : subscriptions.filter { feed in
            unreadFeedIDs.contains(feed.id) || shelf == .feed(feed.id)
        }
        return List(selection: $shelf) {
            sidebarHeader {
                HStack {
                    disclosure("Subscriptions", expanded: $showSubscriptions)
                    Spacer()
                    Button { addingFeed = true } label: {
                        Label("Add subscription", systemImage: "plus").labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help("Add subscription")
                    .disabled(!store.canUseAPI)
                }
            }
            if showSubscriptions {
                Label("All articles", systemImage: "dot.radiowaves.left.and.right").tag(Shelf.rss)
                ForEach(visibleFeeds) { feed in
                    feedRow(feed, hasUnread: unreadFeedIDs.contains(feed.id))
                        .tag(Shelf.feed(feed.id))
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
                Label("All articles", systemImage: "bookmark").tag(Shelf.saved)
                ForEach(tags, id: \.self) { tag in Label(tag, systemImage: "tag").tag(Shelf.tag(tag)) }
            }
            sidebarSectionDivider
            sidebarHeader { Text("Library").fontWeight(.semibold) }
            Label("Starred", systemImage: "star").tag(Shelf.starred)
            Label("Archive", systemImage: "archivebox").tag(Shelf.archive)
            Label("Trash", systemImage: "trash").tag(Shelf.trash)
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, alignment: .leading, spacing: 0) {
            FeedBasketWordmark()
                .padding(.horizontal, BasketTokens.spacing * 1.5)
                .padding(.vertical, BasketTokens.spacing)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            sidebarFooter
        }
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

    private func feedRow(_ feed: Feed, hasUnread: Bool) -> some View {
        HStack(spacing: 6) {
            Label {
                Text(feed.title)
                    .fontWeight(hasUnread ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                Image(systemName: feed.isWebsite ? "globe" : "newspaper")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hasUnread {
                Circle()
                    .fill(shelf == .feed(feed.id) ? AnyShapeStyle(.primary) : AnyShapeStyle(style.accent))
                    .frame(width: 7, height: 7)
                    .padding(.trailing, 3)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(hasUnread ? "Unread articles" : "")
    }

    private var sidebarFooter: some View {
        let status = BasketStatus(online: store.reachable)
        let nextTheme: BasketTheme = style.scheme == .dark ? .light : .dark
        let themeAction = nextTheme == .light ? "Switch to Light Mode" : "Switch to Dark Mode"
        return VStack(spacing: 0) {
            Divider()
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

    private func articleList(_ articles: [Article], selectedArticles: [Article]) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BasketTokens.spacing) {
                HStack {
                    Text(currentFeed?.title ?? current.label)
                        .font(.headline)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Spacer(minLength: BasketTokens.spacing)
                    if let feed = currentFeed {
                        FeedMenu(feed: feed).id(feed.id)
                    }
                }
                if hasSourceFilter {
                    Picker("Source", selection: $source) {
                        ForEach(["All", "Subscriptions", "Read Later"], id: \.self) { Text($0) }
                    }
                } else {
                    readStatusPicker
                }
            }.padding(BasketTokens.spacing * 1.4)
            Divider()
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
                    BasketEmpty(title: "No articles", icon: "tray")
                }
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selection) {
                        ForEach(articles.prefix(limit)) { article in
                            ArticleRow(article: article, archive: hasSourceFilter)
                                .tag(article.id)
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
                    .contextMenu(forSelectionType: String.self) { ids in
                        let targets = articles.prefix(limit).filter { ids.contains($0.id) }
                        if targets.count == 1, let article = targets.first {
                            ForEach(ArticleAction.allCases, id: \.self) { action in
                                if action.allows(article) {
                                    Button(action.title(for: article)) { perform(action, on: article) }
                                }
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
                    .onExitCommand { selection = [] }
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
        .modifier(BasketToastOverlay(location: .articleList))
    }

    private var readStatusPicker: some View {
        Picker("Read status", selection: $readFilter) {
            Text("All").tag("All")
            Text("Unread").tag("Unread")
            Text("Read").tag("Read")
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
    }

    private var emptyReadFilter: some View {
        VStack(spacing: BasketTokens.spacing) {
            Text(readFilter == "All" ? "No articles" : "No \(readFilter.lowercased()) articles")
                .font(.headline)
            if readFilter != "All" {
                Button("Show all articles") { readFilter = "All" }.buttonStyle(.link)
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

    private func perform(_ action: ArticleAction, on article: Article) {
        guard let latest = store.article(article.id), action.allows(latest) else { return }
        switch action {
        case .star:
            store.change(Mutation(articleID: latest.id, starred: !latest.isStarred))
        case .archive, .dislike:
            let articles = selected == latest.id ? visible : []
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
