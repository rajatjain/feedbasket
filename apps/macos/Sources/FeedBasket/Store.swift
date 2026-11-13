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
    private(set) var offlineCount = 0
    private(set) var offlineBytes = 0
    private(set) var updateScope = UUID()
    private(set) var sessionRevision = UUID()
    var storage: Storage?
    private(set) var toasts: [BasketToast.Location: BasketToast] = [:]
    private var lastTrashedArticleID: String?

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
        lastTrashedArticleID = nil
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
        AccessibilityNotification.Announcement(action == .undoTrash ? text + ". Press Command Z to undo." : text).post()
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
        if lastTrashedArticleID != nil && !canUndoTrash { clearTrashUndo() }
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
            try await sendMutations()
            let cursor = library.cursor
            let applied = try await downloadChanges()
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
        lastTrashedArticleID = nil
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

    var canUndoTrash: Bool {
        guard let lastTrashedArticleID else { return false }
        return article(lastTrashedArticleID)?.location == "trash"
    }

    private func clearTrashUndo() {
        lastTrashedArticleID = nil
        if toasts[.reader]?.action == .undoTrash { clearToast(at: .reader) }
    }

    func undoTrash() {
        guard canUndoTrash, let lastTrashedArticleID else { return }
        if change(Mutation(articleID: lastTrashedArticleID, action: "restore")) {
            notify("Restored from Trash")
        }
    }

    @discardableResult
    func change(_ mutation: Mutation, automatic: Bool = false) -> Bool {
        guard profile != nil, let current = article(mutation.articleID) else { return false }
        do {
            var next = library
            var mutation = mutation
            // Persist an absolute restore target so a network retry cannot restore twice.
            if mutation.action == "restore" {
                mutation.action = current.location == "trash" && current.trash_origin == "archive"
                    ? "restore_archive" : "restore_inbox"
            }
            next.pending.append(mutation)
            try persist(next)
            Diagnostics.write("Article change queued \(mutation.logDetails) automatic=\(automatic)")
            if mutation.action == "trash" && current.location != "trash" {
                lastTrashedArticleID = current.id
                notify("Moved to Trash", icon: "trash", action: .undoTrash)
            }
            Task { await refresh(followUp: true) }
            return true
        } catch {
            report(error)
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
            let page: SyncPage = try await api.call("/api/v1/sync?limit=200&after=\(library.cursor)")
            try Task.checkCancellation()
            var next = library
            if page.reset_required {
                guard !reset else { throw APIError(status: 0, detail: "The library could not be reset.") }
                reset = true
                next.articles = [:]
                next.feeds = [:]
                next.cursor = 0
                try persist(next)
                applied = 0
                Diagnostics.write("Library cursor reset; rebuilding from backend")
                continue
            }
            for item in page.items {
                switch item.kind {
                case "article":
                    if let article = item.article {
                        if next.articles[article.id]?.body_bytes != article.body_bytes || article.content_status != "ready" {
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
                    }
                case "feed": next.feeds[item.id] = item.operation == "delete" || item.feed?.active == false ? nil : item.feed
                default: break
                }
            }
            next.cursor = page.cursor
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
        do {
            let detail: Article = try await api.call("/api/v1/articles/" + id)
            guard !Task.isCancelled, scope == updateScope,
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

    private func warmOffline() async {
        guard let disk else { return }
        let inbox = library.articles.values.filter { $0.location == "inbox" }
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

    func previewSubscription(_ url: URL) async throws -> SubscriptionPreview {
        let escaped = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? url.absoluteString
        return try await api.call("/api/v1/feeds/discover?preview=true&check_subscriptions=true&url=" + escaped, timeout: 30)
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
                for _ in 0..<15 {
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

    func unsubscribe(_ feed: Feed) async {
        do {
            _ = try await api.send("/api/v1/feeds/\(feed.id)", method: "DELETE")
            await refresh(followUp: true)
        } catch { report(error) }
    }

    func loadStorage() async {
        guard canUseAPI else { return }
        do { storage = try await api.call("/api/v1/storage") }
        catch { report(error, at: .settings, showToast: false) }
    }

    func setQuota(_ bytes: Int) async {
        do {
            storage = try await api.call("/api/v1/storage", method: "PATCH", body: ["quota_bytes": bytes])
            notify("Storage limit saved.", at: .settings)
        } catch { report(error, at: .settings) }
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
