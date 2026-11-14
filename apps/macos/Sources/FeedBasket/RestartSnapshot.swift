import Foundation

struct RestartSnapshot: Codable {
    let origin: URL
    let accountID: String?
    let libraryID: String?
    let shelf: Shelf
    let selection: Set<String>
    let highlightID: String?
    let listTopID: String?
    let readStatus: String
    let documentType: String
    let source: String
    let highlights: HighlightFilters
    let listLimit: Int
    let columns: Columns
    let readerFocused: Bool
    let showSubscriptions: Bool
    let showSaved: Bool
    var reader: ReaderPosition?

    enum Columns: String, Codable {
        case all, double, detail
    }

    struct HighlightFilters: Codable {
        var grouping = "Recent"
        var documentType = "All"
        var tag = "All tags"
        var search = ""
    }

    enum ReaderPosition: Codable {
        case article(id: String, position: ArticlePosition)
        case pdf(id: String, position: PDFPosition)

        var id: String {
            switch self {
            case .article(let id, _), .pdf(let id, _): id
            }
        }
    }

    struct ArticlePosition: Codable {
        let scrollY: Double
        let anchor: Anchor?

        struct Anchor: Codable {
            let index: Int
            let context: String
            let before: Int
            let top: Double
        }
    }

    struct PDFPosition: Codable {
        let revision: String
        let page: Int
        let point: CGPoint
        let scale: Double?
        let thumbnails: Bool
        var fitPage: Bool? = nil
    }
}

enum RestartHandoff {
    static let argument = "--feedbasket-resume"
    private static let lifetime: TimeInterval = 10 * 60
    private static var directory: URL {
        URL.cachesDirectory.appending(path: "FeedBasket/Restart", directoryHint: .isDirectory)
    }

    static func save(_ snapshot: RestartSnapshot, token: UUID) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let key: URLResourceKey = .contentModificationDateKey
        for file in (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [key])) ?? [] {
            if file.pathExtension == "json", let date = try? file.resourceValues(forKeys: [key]).contentModificationDate,
               Date.now.timeIntervalSince(date) > lifetime {
                try? files.removeItem(at: file)
            }
        }
        try JSONEncoder().encode(snapshot).write(to: file(for: token), options: .atomic)
    }

    static func take(arguments: [String]) -> RestartSnapshot? {
        guard let index = arguments.firstIndex(of: argument), arguments.indices.contains(index + 1),
              let token = UUID(uuidString: arguments[index + 1]) else { return nil }
        let file = file(for: token)
        do {
            let date = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            let data = try Data(contentsOf: file)
            try FileManager.default.removeItem(at: file)
            guard let date, Date.now.timeIntervalSince(date) <= lifetime else { return nil }
            return try JSONDecoder().decode(RestartSnapshot.self, from: data)
        } catch {
            return nil
        }
    }

    static func discard(_ token: UUID) {
        try? FileManager.default.removeItem(at: file(for: token))
    }

    private static func file(for token: UUID) -> URL {
        directory.appending(path: token.uuidString + ".json")
    }
}

@MainActor
final class RestartReaderState {
    var pending: RestartSnapshot.ReaderPosition?
    var capture: (id: String, position: @MainActor () async -> RestartSnapshot.ReaderPosition?)?
}

@MainActor
final class RestartListPosition {
    var viewport = CGRect.null
    private var rows: [String: CGRect] = [:]

    var topID: String? {
        rows.filter { $0.value.maxY > viewport.minY && $0.value.minY < viewport.maxY }
            .min { $0.value.minY < $1.value.minY }?.key
    }

    func update(_ id: String, frame: CGRect?) {
        rows[id] = frame
    }
}
