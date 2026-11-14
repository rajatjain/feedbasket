import Foundation

struct Profile: Codable {
    let username: String?
    let id: String
    let email: String
    let name: String
    let picture: String
}

struct Article: Codable, Identifiable {
    let id: String
    let url: String
    let title: String
    let author: String
    let published_at: Double?
    let created_at: Double
    let saved_at: Double?
    var read: Bool
    var starred: Bool?
    var location: String
    var trash_origin: String?
    var tags: [String]
    let feed_ids: [String]
    let excerpt: String
    let content_status: String
    let content_error: String?
    let body_bytes: Int
    let body_html: String?
    let document_type: String?
    let pdf: PDFMetadata?
    var reading_position: ReadingPosition?

    var date: Date { Date(timeIntervalSince1970: published_at ?? created_at) }
    var original: URL? { URL(string: url) }
    var source: String { original?.host() ?? "" }
    var isStarred: Bool { starred == true }
    var isPDF: Bool { document_type == "pdf" }
}

struct PDFMetadata: Codable {
    let source: String
    let filename: String?
    let size_bytes: Int?
    let page_count: Int?
    let document_revision: String?
    let deletion_pending: Bool
}

struct ReadingPosition: Codable, Equatable {
    let page: Int
    let offset: Double
    let document_revision: String?
    let updated_at: Int
}

struct Highlight: Codable, Identifiable {
    enum Mark: String, Codable {
        case highlight, underline
        var label: String { rawValue.capitalized }
        var icon: String { self == .highlight ? "highlighter" : "underline" }
    }

    struct Anchor: Codable, Equatable {
        struct Quad: Codable, Equatable {
            let page: Int
            let points: [Double]
        }

        let kind: String
        var quads: [Quad]? = nil
        var document_revision: String? = nil
        var prefix: String? = nil
        var suffix: String? = nil
    }

    let id: String
    let article_id: String
    let style: Mark
    let quote: String
    let color: String
    let anchor: Anchor
    let created_at: Double
}

struct LinkPreview: Decodable {
    enum Kind: String, Decodable { case feed, article, pdf, unsupported }
    let kind: Kind
    let url: String
    let title: String?
    let description: String?
    let feeds: [SubscriptionPreview.Candidate]?
}

struct SavedLink: Decodable {
    let article: Article
    let feed: Feed?
}

struct Feed: Codable, Identifiable {
    let id: String
    let url: String
    let title: String
    let custom_title: String?
    let interval_minutes: Int?
    let history_end: Bool
    let active: Bool?
    let initial_done: Bool
    let error: String?
    let kind: String?

    var isWebsite: Bool { kind == "website" }
}

struct SubscriptionPreview: Decodable {
    struct Candidate: Decodable, Identifiable {
        let url: String
        let title: String
        let format: String
        let already_subscribed: Bool?

        var id: String { url }
        var publisher: PublisherIdentity { PublisherIdentity(title: title, url: url) }
    }

    let url: String
    let title: String
    let description: String
    let feeds: [Candidate]
    let already_subscribed: Bool?

    var publisher: PublisherIdentity { PublisherIdentity(title: title, url: url) }
}

struct SyncPage: Decodable {
    struct Change: Decodable {
        let kind: String
        let id: String
        let operation: String
        let replacement_id: String?
        let article: Article?
        let feed: Feed?
        let highlight: Highlight?

        enum CodingKeys: String, CodingKey { case kind, id, operation, replacement_id, data }
        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            kind = try box.decode(String.self, forKey: .kind)
            id = try box.decode(String.self, forKey: .id)
            operation = try box.decode(String.self, forKey: .operation)
            replacement_id = try box.decodeIfPresent(String.self, forKey: .replacement_id)
            article = kind == "article" ? try box.decodeIfPresent(Article.self, forKey: .data) : nil
            feed = kind == "feed" ? try box.decodeIfPresent(Feed.self, forKey: .data) : nil
            highlight = kind == "highlight" ? try box.decodeIfPresent(Highlight.self, forKey: .data) : nil
        }
    }
    let items: [Change]
    let cursor: Int
    let has_more: Bool
    let reset_required: Bool
    let library_id: String?
}

struct Mutation: Codable, Identifiable {
    var id = UUID()
    var articleID: String
    var read: Bool? = nil
    var starred: Bool? = nil
    var action: String? = nil
    var tags: [String]? = nil

    var logDetails: String {
        var fields = ["article_id=\(articleID)", "mutation_id=\(id)"]
        if let read { fields.append("read=\(read)") }
        if let starred { fields.append("starred=\(starred)") }
        if let action { fields.append("action=\(action)") }
        if let tags { fields.append("tag_count=\(tags.count)") }
        return fields.joined(separator: " ")
    }

    var body: [String: Any] {
        var values: [String: Any] = [:]
        values["read"] = read
        values["starred"] = starred
        values["action"] = action
        values["tags"] = tags
        return values
    }
}

struct AccountConnection: Decodable {
    let token: String
    let profile: Profile
}

struct Job: Decodable {
    let status: String
    let error: String?
}

struct JobRequest: Decodable {
    let job_id: Int?
    let message: String?
}

struct Storage: Decodable {
    let used_bytes: Int
    let quota_bytes: Int
    let pdf_used_bytes: Int?
    let pdf_quota_bytes: Int?
}

struct APIError: LocalizedError {
    let status: Int
    let detail: String
    var errorDescription: String? { detail }
}

struct API {
    let origin: URL
    let token: String?

    static func origin(_ text: String) throws -> URL {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host, !host.isEmpty,
              parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
              parts.user == nil, parts.password == nil,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.fragment == nil else {
            throw APIError(status: 0, detail: "Enter an HTTPS origin or a local HTTP URL.")
        }
        parts.path = ""
        guard let url = parts.url else { throw APIError(status: 0, detail: "Invalid API URL.") }
        return url
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirect(), delegateQueue: nil)

    static func endpoint(_ path: String, _ query: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = query
        // Query parsers treat a literal plus in form-style queries as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.string ?? path
    }

    @MainActor
    func watchSavedUpdates(onUpdate: @MainActor () async -> Void) async throws {
        var request = URLRequest(url: origin.appending(path: "/api/v1/updates"), timeoutInterval: 40)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (bytes, response) = try await Self.session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200, response.mimeType == "text/event-stream" else {
            throw APIError(status: status, detail: "Saved article updates are unavailable.")
        }
        for try await line in bytes.lines {
            try Task.checkCancellation()
            if line == "data: sync" { await onUpdate() }
        }
    }

    func call<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                            timeout: TimeInterval = 8) async throws -> T {
        let data = try await send(path, method: method, body: body, timeout: timeout)
        return try JSONDecoder().decode(T.self, from: data)
    }

    @discardableResult
    func send(_ path: String, method: String = "GET", body: [String: Any]? = nil,
              timeout: TimeInterval = 8) async throws -> Data {
        var request = makeRequest(path, method: method, timeout: timeout)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await Self.session.data(for: request)
        return try checked(data, response)
    }

    func importPDF(_ file: URL, id: UUID, tags: [String]) async throws -> Article {
        let path = Self.endpoint("/api/v1/pdfs/import", [
            URLQueryItem(name: "import_id", value: id.uuidString), URLQueryItem(name: "filename", value: file.lastPathComponent),
        ] + tags.map { URLQueryItem(name: "tags", value: $0) })
        var request = makeRequest(path, method: "POST", timeout: 300)
        request.setValue("application/pdf", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await Self.session.upload(for: request, fromFile: file)
        return try JSONDecoder().decode(Article.self, from: checked(data, response))
    }

    private func makeRequest(_ path: String, method: String, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: URL(string: origin.absoluteString + path)!, timeoutInterval: timeout)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func checked(_ data: Data, _ response: URLResponse) throws -> Data {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let detail = object?["detail"]
            throw APIError(status: status, detail: detail as? String ?? (detail as? [String: Any])?["message"] as? String
                           ?? "Backend returned HTTP \(status).")
        }
        return data
    }

    func health() async throws {
        struct Health: Decodable { let status: String }
        let result: Health = try await API(origin: origin, token: nil).call("/health")
        guard result.status == "ok" else { throw APIError(status: 0, detail: "Unexpected backend response.") }
    }
}
