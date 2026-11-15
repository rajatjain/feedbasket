import AppKit
import Foundation
import Observation

@MainActor @Observable
final class BasketStore {
    static let defaultOrigin = "http://127.0.0.1:12000"
    private(set) var origin: URL
    private(set) var profile: Profile?
    private(set) var library = Library()
    private(set) var reachable = false
    private(set) var authenticated = false
    private(set) var busy = false
    private(set) var signingIn = false
    private(set) var syncIssue: String?
    private(set) var readerRefreshes: Set<String> = []
    private(set) var offlineCount = 0
    private(set) var offlineBytes = 0
    private(set) var updateScope = UUID()
    private(set) var sessionRevision = UUID()
    var storage: Storage?
    private(set) var toasts: [BasketToast.Location: BasketToast] = [:]
    private var articleUndo: (action: ArticleBatchAction, ids: [String], location: BasketToast.Location)?

    @ObservationIgnored private var token: String?
    @ObservationIgnored private var needsSignIn = false
    @ObservationIgnored private var disk: Disk?
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var needsSync = false
    @ObservationIgnored private var offlineTask: Task<Void, Never>?
    @ObservationIgnored private var loginTask: Task<Void, Never>?
    @ObservationIgnored private var toastTasks: [BasketToast.Location: Task<Void, Never>] = [:]
    @ObservationIgnored private var blockedCopies: Set<String> = []
    private var readerBodies: [String: String] = [:]

    var api: API { API(origin: origin, token: token) }
    var canUseAPI: Bool { reachable && authenticated }
    private var profileKey: String { "profile:" + origin.absoluteString }

    init() {
        origin = (try? API.origin(UserDefaults.standard.string(forKey: "origin") ?? Self.defaultOrigin))
            ?? URL(string: Self.defaultOrigin)!
        loadScope()
    }

    func setOrigin(_ text: String) async {
        do {
            let newOrigin = try API.origin(text)
            guard newOrigin != origin else { return }
            loginTask?.cancel()
            await stopSync()
            origin = newOrigin
            UserDefaults.standard.set(origin.absoluteString, forKey: "origin")
            loadScope()
            await refresh()
        } catch { report(error, at: .settings) }
    }

    private func loadScope() {
        updateScope = UUID()
        syncIssue = nil
        articleUndo = nil
        clearToasts()
        setToken(nil)
        needsSignIn = false
        profile = UserDefaults.standard.data(forKey: profileKey).flatMap { try? JSONDecoder().decode(Profile.self, from: $0) }
        reachable = false
        openLibrary()
    }

    private func setToken(_ token: String?) {
        self.token = token
        authenticated = token != nil
        sessionRevision = UUID()
    }

    private func openLibrary() {
        library = Library()
        readerBodies = [:]
        blockedCopies = Set(UserDefaults.standard.stringArray(forKey: blockKey) ?? [])
        storage = nil
        disk = profile.map { Disk(origin: origin.absoluteString, account: $0.id) }
        do { if let disk { library = try disk.load() } }
        catch { report(error) }
        updateUsage()
    }

    private var blockKey: String { "offline-removals:" + origin.absoluteString + ":" + (profile?.id ?? "") }

    func notify(_ text: String, icon: String = "checkmark.circle", at location: BasketToast.Location = .reader,
                action: BasketToast.Action? = nil) {
        toastTasks[location]?.cancel()
        let notice = BasketToast(text: text, icon: icon, action: action)
        toasts[location] = notice
        AccessibilityNotification.Announcement(action == .undoArticleChange ? text + ". Press Command Z to undo." : text).post()
        toastTasks[location] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            if self?.toasts[location]?.id == notice.id { self?.clearToast(at: location) }
        }
    }

    private func clearToast(at location: BasketToast.Location) {
        toastTasks.removeValue(forKey: location)?.cancel()
        toasts[location] = nil
    }

    private func clearToasts() {
        for task in toastTasks.values { task.cancel() }
        toastTasks.removeAll()
        toasts.removeAll()
    }

    func report(_ error: Error, at location: BasketToast.Location = .reader, showToast: Bool = true) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        if let error = error as? APIError {
            Diagnostics.write("API operation failed (status \(error.status))", level: "WARNING")
        } else if let error = error as? URLError {
            if reachable { Diagnostics.write("Backend connection interrupted (\(error.code.rawValue))", level: "WARNING") }
        } else {
            Diagnostics.write("Operation failed (\(type(of: error)))", level: "WARNING")
        }
        if let error = error as? APIError, [401, 403].contains(error.status) {
            authenticated = false
            syncIssue = "Sign in again to sync your library."
            if showToast { notify("Sign in again to sync your library.", icon: "person.crop.circle.badge.exclamationmark", at: location) }
        } else {
            if error is URLError { reachable = false }
            if showToast { notify(error.localizedDescription, icon: "exclamationmark.circle", at: location) }
        }
    }

    private func persist(_ snapshot: Library) throws {
        guard let disk else { return }
        try disk.save(snapshot)
        library = snapshot
        if articleUndo != nil && !canUndoArticleChange { clearArticleUndo() }
    }

    func refresh(followUp: Bool = false) async {
        guard !Task.isCancelled else { return }
        if let syncTask {
            if followUp { needsSync = true }
            await syncTask.value
            return
        }
        let work = Task {
            defer { syncTask = nil }
            repeat {
                needsSync = false
                await runSync()
            } while needsSync && !Task.isCancelled
        }
        syncTask = work
        await work.value
    }

    func refreshManually() async {
        let scope = updateScope
        await refresh(followUp: true)
        guard scope == updateScope else { return }
        if let syncIssue { notify(syncIssue, icon: "exclamationmark.circle") }
        else if authenticated { notify("Library synced.") }
        else { notify("Sign in to sync your library.", icon: "person.crop.circle") }
    }

    private func stopSync() async {
        if let syncTask {
            syncTask.cancel()
            await syncTask.value
        }
        offlineTask?.cancel()
        await offlineTask?.value
        offlineTask = nil
    }

    func watchSavedUpdates(revision: UUID) async {
        guard token != nil, revision == sessionRevision else { return }
        let endpoint = api
        var delay = 1
        var connected = false
        while !Task.isCancelled && revision == sessionRevision {
            do {
                try await endpoint.watchSavedUpdates {
                    guard !Task.isCancelled, revision == self.sessionRevision else { return }
                    if !connected {
                        Diagnostics.write("Saved article updates connected")
                        connected = true
                    }
                    delay = 1
                    await self.refresh(followUp: true)
                }
                // The backend periodically renews the stream to check account access.
                delay = 1
            } catch let error as APIError where [401, 403, 404, 405].contains(error.status) {
                // The regular sync checks session state and supports older backends.
                return
            } catch {
                if Task.isCancelled { return }
                if connected {
                    Diagnostics.write("Saved article update connection interrupted", level: "WARNING")
                    connected = false
                }
            }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            delay = min(delay * 2, 15)
        }
    }

    private func runSync() async {
        busy = true
        defer { busy = false }
        do {
            offlineTask?.cancel()
            await offlineTask?.value
            offlineTask = nil
            try Task.checkCancellation()
            try await api.health()
            try Task.checkCancellation()
            if !reachable { Diagnostics.write("Backend reachable") }
            reachable = true
            guard try await syncProfile() else { return }
            let cursor = library.cursor
            var applied = try await downloadChanges()
            if !library.pending.isEmpty || library.pendingPositions?.isEmpty == false {
                try await sendMutations()
                try await sendPDFPositions()
                applied += try await downloadChanges()
            }
            syncIssue = nil
            if cursor != library.cursor || applied > 0 {
                Diagnostics.write("Library synced previous_cursor=\(cursor) cursor=\(library.cursor) changes=\(applied)")
            }
            offlineTask = Task { await warmOffline() }
        } catch {
            guard !Task.isCancelled else { return }
            syncIssue = error.localizedDescription
            report(error, showToast: false)
        }
    }

    private func syncProfile() async throws -> Bool {
        if token != nil {
            do {
                let user: Profile = try await api.call("/api/v1/me")
                try Task.checkCancellation()
                try remember(user)
                authenticated = true
                return true
            } catch let error as APIError where error.status == 401 {
                setToken(nil)
            }
        }
        guard !needsSignIn, let saved = profile, let username = saved.username else {
            syncIssue = profile == nil ? nil : "Sign in again to sync your library."
            return false
        }
        do {
            let login = try await requestSession(username)
            try Task.checkCancellation()
            guard login.profile.id == saved.id else {
                needsSignIn = true
                syncIssue = "The saved username points to a different account on this server. Sign in to choose an account."
                return false
            }
            try remember(login.profile)
            setToken(login.token)
            Diagnostics.write("Account reconnected")
            return true
        } catch let error as APIError where [401, 403, 404, 422].contains(error.status) {
            needsSignIn = true
            syncIssue = "Sign in again to sync your library."
            return false
        }
    }

    private func requestSession(_ username: String, create: Bool = false) async throws -> AccountConnection {
        let path = create ? "signup" : "connect"
        return try await API(origin: origin, token: nil).call("/api/v1/auth/" + path, method: "POST", body: [
            "username": username.trimmingCharacters(in: .whitespacesAndNewlines), "temporary_session": true,
        ])
    }

    private func remember(_ user: Profile) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(user), forKey: profileKey)
        let accountChanged = profile?.id != user.id
        profile = user
        if accountChanged { openLibrary() }
    }

    func signIn(_ username: String, create: Bool = false) {
        guard loginTask == nil else { return }
        let scope = updateScope
        loginTask = Task {
            signingIn = true
            defer { signingIn = false; loginTask = nil }
            do {
                let login = try await requestSession(username, create: create)
                try Task.checkCancellation()
                guard scope == updateScope else { return }
                try await acceptSession(login.token, profile: login.profile)
            } catch {
                if let error = error as? APIError, error.status == 401 {
                    notify(error.localizedDescription, icon: "exclamationmark.circle")
                }
                else { report(error) }
            }
        }
    }

    private func acceptSession(_ token: String, profile: Profile) async throws {
        await stopSync()
        try Task.checkCancellation()
        try remember(profile)
        setToken(token)
        needsSignIn = false
        syncIssue = nil
        Diagnostics.write("Account connected")
        updateScope = UUID()
        articleUndo = nil
        clearToasts()
        await refresh()
    }

    func signOut() async {
        loginTask?.cancel()
        await stopSync()
        let endpoint = api
        UserDefaults.standard.removeObject(forKey: profileKey)
        loadScope()
        if endpoint.token != nil { _ = try? await endpoint.send("/api/v1/auth/logout", method: "POST") }
        await refresh()
    }

    var canUndoArticleChange: Bool {
        guard let articleUndo else { return false }
        return articleUndo.ids.contains { id in
            article(id).flatMap { articleUndo.action.inverse(for: $0) } != nil
        }
    }

    private func clearArticleUndo() {
        if let location = articleUndo?.location, toasts[location]?.action == .undoArticleChange {
            clearToast(at: location)
        }
        articleUndo = nil
    }

    private func rememberArticleUndo(_ action: ArticleBatchAction, ids: [String], at location: BasketToast.Location,
                                     message: String) {
        clearArticleUndo()
        articleUndo = (action, ids, location)
        notify(message, icon: action.icon, at: location, action: .undoArticleChange)
    }

    func undoArticleChange() {
        guard let articleUndo else { return }
        let mutations = articleUndo.ids.compactMap(article).compactMap(articleUndo.action.inverse)
        if queueChanges(mutations, at: articleUndo.location) {
            clearArticleUndo()
            let message = articleUndo.location == .reader ? "Restored from Trash" : "Undid \(articleUndo.action.title.lowercased())"
            notify(message, at: articleUndo.location)
        }
    }

    func changeArticles(_ ids: [String], action: ArticleBatchAction) -> Bool {
        let articles = ids.compactMap(article).filter(action.allows)
        guard queueChanges(articles.map(action.mutation), at: .articleList) else { return false }
        rememberArticleUndo(action, ids: articles.map(\.id), at: .articleList, message: action.confirmation(count: articles.count))
        return true
    }

    @discardableResult
    func change(_ mutation: Mutation, automatic: Bool = false) -> Bool {
        guard profile != nil, let current = article(mutation.articleID) else { return false }
        var mutation = mutation
        // Persist an absolute restore target so a network retry cannot restore twice.
        if mutation.action == "restore" {
            mutation.action = current.location == "trash" && current.trash_origin == "archive"
                ? "restore_archive" : "restore_inbox"
        }
        guard queueChanges([mutation], automatic: automatic) else { return false }
        if mutation.action == "trash" && current.location != "trash" {
            rememberArticleUndo(.trash, ids: [current.id], at: .reader, message: "Moved to Trash")
        }
        return true
    }

    private func queueChanges(_ mutations: [Mutation], automatic: Bool = false,
                              at location: BasketToast.Location = .reader) -> Bool {
        guard profile != nil, disk != nil, !mutations.isEmpty else { return false }
        do {
            var next = library
            next.pending.append(contentsOf: mutations)
            try persist(next)
            for mutation in mutations {
                Diagnostics.write("Article change queued \(mutation.logDetails) automatic=\(automatic)")
            }
            Task { await refresh(followUp: true) }
            return true
        } catch {
            report(error, at: location)
            return false
        }
    }

    func article(_ id: String) -> Article? {
        guard var article = library.articles[id] else { return nil }
        var priorLocation = article.trash_origin ?? "inbox"
        for mutation in library.pending where mutation.articleID == id {
            if let read = mutation.read { article.read = read }
            if let starred = mutation.starred { article.starred = starred }
            if let tags = mutation.tags { article.tags = tags }
            switch mutation.action {
            case "trash" where article.location != "trash":
                priorLocation = article.location
                article.trash_origin = priorLocation
                article.location = "trash"
            case "archive" where article.location == "inbox": article.location = "archive"
            case "restore" where article.location != "inbox":
                article.location = article.location == "trash" ? priorLocation : "inbox"
                article.trash_origin = nil
            case "restore_archive" where article.location == "trash":
                article.location = "archive"
                article.trash_origin = nil
            case "restore_inbox" where article.location != "inbox":
                article.location = "inbox"
                article.trash_origin = nil
            default: break
            }
        }
        return article
    }

    private func sendMutations() async throws {
        while let mutation = library.pending.first {
            try Task.checkCancellation()
            do {
                let article: Article = try await api.call("/api/v1/articles/" + mutation.articleID, method: "PATCH", body: mutation.body)
                try Task.checkCancellation()
                var next = library
                if article.id != mutation.articleID { next.articles.removeValue(forKey: mutation.articleID) }
                next.articles[article.id] = article
                next.pending.removeAll { $0.id == mutation.id }
                try persist(next)
                Diagnostics.write("Article change synced \(mutation.logDetails) result_article_id=\(article.id)")
            } catch let error as APIError where [404, 422].contains(error.status) {
                var next = library
                next.pending.removeAll { $0.id == mutation.id }
                try persist(next)
                Diagnostics.write("Article change rejected \(mutation.logDetails) status=\(error.status)", level: "WARNING")
                notify(error.localizedDescription, icon: "exclamationmark.circle")
            }
        }
    }

    private func downloadChanges() async throws -> Int {
        var reset = false
        var applied = 0
        while true {
            try Task.checkCancellation()
            var endpoint = "/api/v1/sync?limit=200&after=\(library.cursor)"
            if let id = library.libraryID {
                endpoint += "&library_id=\(id)"
            } else if library.cursor > 0 {
                // A cache from before library IDs existed needs one fresh sync.
                endpoint += "&library_id="
            }
            let page: SyncPage = try await api.call(endpoint)
            try Task.checkCancellation()
            var next = library
            if page.reset_required {
                guard !reset else { throw APIError(status: 0, detail: "The library could not be reset.") }
                reset = true
                next.articles = [:]
                next.feeds = [:]
                next.highlights = [:]
                next.cursor = 0
                next.libraryID = page.library_id
                try disk?.clearCopies()
                readerBodies = [:]
                updateUsage()
                try persist(next)
                applied = 0
                Diagnostics.write("Library cursor reset; rebuilding from backend")
                continue
            }
            for item in page.items {
                switch item.kind {
                case "article":
                    if let article = item.article {
                        if article.content_status != "ready" ||
                            (next.articles[article.id]?.body_bytes != article.body_bytes && !readerRefreshes.contains(article.id)) {
                            try disk?.remove(article.id)
                            readerBodies[article.id] = nil
                        }
                        next.articles[article.id] = article
                    } else {
                        next.articles[item.id] = nil
                        try disk?.remove(item.id)
                        readerBodies[item.id] = nil
                        if let replacement = item.replacement_id {
                            for index in next.pending.indices where next.pending[index].articleID == item.id {
                                next.pending[index].articleID = replacement
                            }
                        } else {
                            next.pending.removeAll { $0.articleID == item.id }
                        }
                        next.pendingPositions?[item.id] = nil
                    }
                case "feed": next.feeds[item.id] = item.operation == "delete" || item.feed?.active == false ? nil : item.feed
                case "highlight":
                    var highlights = next.highlights ?? [:]
                    highlights[item.id] = item.operation == "delete" ? nil : item.highlight
                    next.highlights = highlights
                default: break
                }
            }
            next.cursor = page.cursor
            next.libraryID = page.library_id
            try persist(next)
            applied += page.items.count
            if !page.has_more { return applied }
        }
    }

    func html(for id: String) -> String? { readerBodies[id] ?? disk?.read(id)?.html }
    func offline(_ id: String) -> Bool { disk?.read(id) != nil }

    func loadReader(_ article: Article) async -> String? {
        let id = article.id
        guard html(for: id) == nil, canUseAPI,
              ["ready", "failed"].contains(article.content_status) else { return nil }
        let scope = updateScope
        let libraryID = library.libraryID
        do {
            let detail: Article = try await api.call("/api/v1/articles/" + id)
            guard !Task.isCancelled, scope == updateScope, libraryID == library.libraryID,
                  library.articles[id]?.content_status == article.content_status else { return nil }
            if article.content_status == "ready" { readerBodies[id] = detail.body_html }
            return detail.content_error
        } catch {
            if scope == updateScope { report(error) }
            return nil
        }
    }

    func retryReader(_ id: String) async {
        guard canUseAPI else { return }
        let scope = updateScope
        do {
            _ = try await api.send("/api/v1/articles/\(id)/extract", method: "POST")
            guard scope == updateScope else { return }
            await refresh(followUp: true)
        } catch {
            if scope == updateScope { report(error) }
        }
    }

    func refreshReaderContent(_ id: String) async {
        guard canUseAPI, readerRefreshes.insert(id).inserted else { return }
        let scope = updateScope
        let libraryID = library.libraryID
        let api = self.api
        defer { readerRefreshes.remove(id) }
        do {
            let job: JobRequest = try await api.call("/api/v1/articles/\(id)/refresh-reader", method: "POST")
            guard scope == updateScope, libraryID == library.libraryID else { return }
            guard let jobID = job.job_id else { throw APIError(status: 0, detail: "Reader refresh could not be queued.") }
            notify("Refreshing reader content…", icon: "arrow.clockwise")

            for _ in 0..<90 {
                try await Task.sleep(for: .seconds(1))
                guard scope == updateScope, libraryID == library.libraryID else { return }
                let status: Job = try await api.call("/api/v1/jobs/\(jobID)")
                if status.status == "failed" {
                    throw APIError(status: 0, detail: status.error ?? "Could not refresh reader content.")
                }
                guard status.status == "done" else { continue }

                let detail: Article = try await api.call("/api/v1/articles/\(id)")
                guard scope == updateScope, libraryID == library.libraryID else { return }
                guard let html = detail.body_html else {
                    throw APIError(status: 0, detail: "The backend did not return refreshed reader content.")
                }
                if !blockedCopies.contains(detail.id), let disk, disk.read(detail.id) != nil || detail.saved_at != nil {
                    try disk.store(OfflineCopy(date: detail.date, html: html), id: detail.id)
                    updateUsage()
                }
                readerBodies[detail.id] = html
                await refresh(followUp: true)
                guard scope == updateScope, libraryID == library.libraryID else { return }
                notify("Reader content refreshed.")
                return
            }
            notify("Reader refresh is still queued or running.", icon: "clock")
        } catch is CancellationError {
        } catch {
            if scope == updateScope, libraryID == library.libraryID { report(error) }
        }
    }

    private func warmOffline() async {
        guard let disk else { return }
        let inbox = library.articles.values.filter { $0.location == "inbox" && !$0.isPDF }
        var wanted = Set(inbox.filter { $0.saved_at != nil }.map(\.id))
        var byFeed: [String: [Article]] = [:]
        for article in inbox {
            for feed in article.feed_ids where library.feeds[feed] != nil {
                byFeed[feed, default: []].append(article)
            }
        }
        for articles in byFeed.values {
            wanted.formUnion(articles.sorted { $0.date > $1.date }.prefix(10).map(\.id))
        }
        do {
            let existing = Set(try disk.copies().map(\.id))
            for id in existing.subtracting(wanted) { try disk.remove(id) }
            let missing = wanted.subtracting(existing).subtracting(blockedCopies).compactMap { library.articles[$0] }
                .filter { $0.content_status == "ready" }.sorted {
                    if ($0.saved_at != nil) != ($1.saved_at != nil) { return $0.saved_at != nil }
                    return $0.date > $1.date
                }
            for article in missing.prefix(12) {
                try Task.checkCancellation()
                let detail: Article = try await api.call("/api/v1/articles/" + article.id)
                try Task.checkCancellation()
                if let body = detail.body_html, !blockedCopies.contains(article.id) {
                    try disk.store(OfflineCopy(date: detail.date, html: body), id: detail.id)
                    readerBodies.removeValue(forKey: detail.id)
                }
            }
        } catch { report(error, showToast: false) }
        updateUsage()
    }

    func clearOffline(before: Date?) {
        guard let disk else { return }
        do {
            for copy in try disk.copies() {
                if let before, let stored = disk.read(copy.id), stored.date >= before { continue }
                try disk.remove(copy.id)
                readerBodies[copy.id] = nil
                blockedCopies.insert(copy.id)
            }
            UserDefaults.standard.set(Array(blockedCopies), forKey: blockKey)
            updateUsage()
            notify("Offline copies removed.", at: .settings)
        } catch { report(error, at: .settings) }
    }

    func resumeDownloads() {
        blockedCopies = []
        UserDefaults.standard.removeObject(forKey: blockKey)
        Task { await refresh() }
    }

    private func updateUsage() {
        let copies = (try? disk?.copies()) ?? []
        offlineCount = copies.count
        offlineBytes = copies.reduce(0) { $0 + $1.bytes }
    }

    func previewLink(_ url: URL) async throws -> LinkPreview {
        try await api.call(API.endpoint("/api/v1/links/preview", [URLQueryItem(name: "url", value: url.absoluteString)]), timeout: 30)
    }

    func saveLink(_ url: String, title: String, tags: [String], pdf: Bool, feed: String?) async throws -> SavedLink {
        let scope = updateScope
        var body: [String: Any] = ["url": url, "title": String(title.prefix(500)), "tags": tags,
                                   "document_type": pdf ? "pdf" : "article"]
        body["subscribe_url"] = feed
        let result: SavedLink = try await api.call("/api/v1/articles", method: "POST", body: body, timeout: 30)
        try await acceptSavedDocument(result.article, feed: result.feed, scope: scope)
        return result
    }

    func importPDF(_ file: URL, id: UUID, tags: [String]) async throws -> Article {
        let scope = updateScope
        let result = try await api.importPDF(file, id: id, tags: tags)
        try await acceptSavedDocument(result, scope: scope)
        await loadStorage()
        guard scope == updateScope else { throw CancellationError() }
        return result
    }

    private func acceptSavedDocument(_ article: Article, feed: Feed? = nil, scope: UUID) async throws {
        guard scope == updateScope else { throw CancellationError() }
        var next = library
        next.articles[article.id] = article
        if let feed { next.feeds[feed.id] = feed }
        try persist(next)
        await syncAfterDocumentChange(scope)
        guard scope == updateScope else { throw CancellationError() }
    }

    private func syncAfterDocumentChange(_ scope: UUID) async {
        guard scope == updateScope else { return }
        await refresh(followUp: true)
    }

    func pdfURL(for article: Article) async throws -> URL {
        if article.pdf?.source == "link", let url = article.original { return url }
        struct Download: Decodable { let url: URL }
        let download: Download = try await api.call("/api/v1/pdfs/\(article.id)/download")
        return download.url
    }

    func readingPosition(for article: Article) -> ReadingPosition? {
        let queued = library.pendingPositions?[article.id]
        let saved = library.articles[article.id]?.reading_position ?? article.reading_position
        if let queued, queued.updated_at > (saved?.updated_at ?? 0) { return queued }
        return saved
    }

    func rememberPDFPosition(_ position: ReadingPosition, articleID: String, scope: UUID) {
        guard scope == updateScope, let article = library.articles[articleID], article.pdf?.deletion_pending != true else { return }
        if let previous = readingPosition(for: article) {
            guard position.updated_at > previous.updated_at,
                  previous.page != position.page || abs(previous.offset - position.offset) >= 0.01 else { return }
        }
        do {
            var next = library
            var positions = next.pendingPositions ?? [:]
            positions[articleID] = position
            next.pendingPositions = positions
            try persist(next)
            if canUseAPI { Task { await refresh(followUp: true) } }
        } catch { report(error) }
    }

    private func sendPDFPositions() async throws {
        for (id, position) in library.pendingPositions ?? [:] {
            try Task.checkCancellation()
            var saved: ReadingPosition?
            do {
                saved = try await api.call("/api/v1/pdfs/\(id)/position", method: "PUT", body: [
                    "page": position.page, "offset": position.offset, "updated_at": position.updated_at,
                    "document_revision": position.document_revision as Any? ?? NSNull(),
                ])
            } catch let error as APIError where [404, 409, 422].contains(error.status) {
                Diagnostics.write("PDF position rejected (status \(error.status))", level: "WARNING")
            }
            try Task.checkCancellation()
            var next = library
            if let saved { next.articles[id]?.reading_position = saved }
            if next.pendingPositions?[id] == position { next.pendingPositions?[id] = nil }
            try persist(next)
        }
    }

    func saveHighlight(article: Article, mark: Highlight.Mark, quote: String, anchor: Highlight.Anchor) async throws {
        let scope = updateScope
        let encoded = try JSONEncoder().encode(anchor)
        let result: Highlight = try await api.call("/api/v1/articles/\(article.id)/highlights", method: "POST", body: [
            "id": UUID().uuidString, "style": mark.rawValue, "quote": quote,
            "color": "#ffe873", "anchor": try JSONSerialization.jsonObject(with: encoded),
        ])
        guard scope == updateScope else { throw CancellationError() }
        var next = library
        var highlights = next.highlights ?? [:]
        highlights[result.id] = result
        next.highlights = highlights
        try persist(next)
        await syncAfterDocumentChange(scope)
    }

    func removeHighlight(_ item: Highlight) async {
        let scope = updateScope
        do {
            try await api.send("/api/v1/highlights/\(item.id)", method: "DELETE")
            guard scope == updateScope else { return }
            var next = library
            next.highlights?[item.id] = nil
            try persist(next)
            await syncAfterDocumentChange(scope)
        } catch { if scope == updateScope { report(error) } }
    }

    func permanentlyDeletePDF(_ article: Article) async {
        let scope = updateScope
        do {
            let response = try await api.send("/api/v1/pdfs/\(article.id)/permanent", method: "DELETE")
            await syncAfterDocumentChange(scope)
            guard scope == updateScope else { return }
            notify(response.isEmpty ? "PDF deleted." : "PDF deletion queued.", at: .articleList)
            await loadStorage()
        } catch { if scope == updateScope { report(error, at: .articleList) } }
    }

    func linkedFeeds(for articleID: String) async throws -> [SubscriptionPreview.Candidate] {
        try await api.call("/api/v1/articles/\(articleID)/linked-feeds", timeout: 50)
    }

    func subscribe(url: String, title: String, website: Bool) async throws -> Feed {
        let scope = updateScope
        let feed: Feed = try await api.call("/api/v1/feeds", method: "POST", body: [
            "url": url, "title": title, "kind": website ? "website" : "feed",
        ])
        guard scope == updateScope else { throw CancellationError() }
        await refresh(followUp: true)
        guard scope == updateScope else { throw CancellationError() }
        return feed
    }

    func feedAction(_ feed: Feed, path: String, recheck: Bool = false) async {
        let scope = updateScope
        let api = self.api
        do {
            let endpoint = "/api/v1/feeds/\(feed.id)/" + path + (recheck ? "?recheck=true" : "")
            let job: JobRequest = try await api.call(endpoint, method: "POST", body: [:])
            guard scope == updateScope else { return }
            notify(job.message ?? (path == "older" ? "Older articles queued." : "Feed refresh queued."),
                   icon: job.job_id == nil ? "info.circle" : "clock")
            if let id = job.job_id {
                for _ in 0..<35 {
                    try await Task.sleep(for: .seconds(2))
                    guard scope == updateScope else { return }
                    let status: Job = try await api.call("/api/v1/jobs/\(id)")
                    guard scope == updateScope else { return }
                    if status.status == "done" || status.status == "failed" {
                        let failed = status.status == "failed"
                        let success = path == "older" ? "Feed history updated." : "Feed refreshed."
                        notify(status.error ?? (failed ? "Feed update failed." : success),
                               icon: failed ? "exclamationmark.circle" : "checkmark.circle")
                        break
                    }
                }
            }
            await refresh(followUp: true)
        } catch { if scope == updateScope { report(error) } }
    }

    func setInterval(_ value: Int, feed: Feed) async {
        do {
            _ = try await api.send("/api/v1/feeds/\(feed.id)", method: "PATCH",
                                   body: ["interval_minutes": value == 0 ? NSNull() : value as Any])
            await refresh()
        } catch { report(error) }
    }

    func markFeedAsRead(_ feed: Feed) {
        let ids = library.articles.values.compactMap { cached -> String? in
            guard cached.feed_ids.contains(feed.id), let article = article(cached.id),
                  article.location == "inbox", !article.read else { return nil }
            return article.id
        }
        _ = changeArticles(ids, action: .read)
    }

    func renameFeed(_ feed: Feed, title: String?) async throws {
        let scope = updateScope
        _ = try await api.send("/api/v1/feeds/\(feed.id)", method: "PATCH",
                               body: ["custom_title": title as Any? ?? NSNull()])
        try Task.checkCancellation()
        guard scope == updateScope else { throw CancellationError() }
        await refresh(followUp: true)
    }

    func unsubscribe(_ feed: Feed) async {
        do {
            _ = try await api.send("/api/v1/feeds/\(feed.id)", method: "DELETE")
            await refresh(followUp: true)
        } catch { report(error) }
    }

    func loadStorage() async {
        guard canUseAPI else { return }
        let scope = updateScope
        do {
            let result: Storage = try await api.call("/api/v1/storage")
            if scope == updateScope { storage = result }
        } catch { if scope == updateScope { report(error, at: .settings, showToast: false) } }
    }

    func setQuota(_ bytes: Int, pdf: Bool = false) async {
        let scope = updateScope
        do {
            let path = pdf ? "/api/v1/storage/pdfs" : "/api/v1/storage"
            let result: Storage = try await api.call(path, method: "PATCH", body: ["quota_bytes": bytes])
            guard scope == updateScope else { return }
            storage = result
            notify(pdf ? "PDF storage limit saved." : "Article storage limit saved.", at: .settings)
        } catch { if scope == updateScope { report(error, at: .settings) } }
    }

    func clearBackendContent(before: Date?) async {
        do {
            let body = before.map { ["before": Int($0.timeIntervalSince1970)] } ?? [:]
            _ = try await api.send("/api/v1/storage/remove-content", method: "POST", body: body)
            await loadStorage()
            await refresh()
            notify("Article bodies removed.", at: .settings)
        } catch { report(error, at: .settings) }
    }
}
