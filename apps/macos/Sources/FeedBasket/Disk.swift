import Foundation
import CryptoKit

struct Library: Codable {
    var articles: [String: Article] = [:]
    var feeds: [String: Feed] = [:]
    var pending: [Mutation] = []
    var cursor = 0
    var libraryID: String?
    var highlights: [String: Highlight]?
    var pendingPositions: [String: ReadingPosition]?
}

struct OfflineCopy: Codable {
    let date: Date
    let html: String
}

struct Disk {
    let directory: URL

    init(origin: String, account: String) {
        let scope = SHA256.hash(data: Data((origin + "\n" + account).utf8))
            .map { String(format: "%02x", $0) }.joined()
        directory = URL.applicationSupportDirectory
            .appending(path: "FeedBasket", directoryHint: .isDirectory)
            .appending(path: scope, directoryHint: .isDirectory)
    }

    var bodies: URL { directory.appending(path: "Offline", directoryHint: .isDirectory) }
    var libraryFile: URL { directory.appending(path: "Library.json") }

    func load() throws -> Library {
        guard FileManager.default.fileExists(atPath: libraryFile.path) else { return Library() }
        return try JSONDecoder().decode(Library.self, from: Data(contentsOf: libraryFile))
    }

    func save(_ library: Library) throws {
        try write(library, to: libraryFile)
    }

    func read(_ id: String) -> OfflineCopy? {
        guard let data = try? Data(contentsOf: copyURL(id)) else { return nil }
        return try? JSONDecoder().decode(OfflineCopy.self, from: data)
    }

    func store(_ copy: OfflineCopy, id: String) throws {
        try write(copy, to: copyURL(id))
    }

    func remove(_ id: String) throws {
        let url = copyURL(id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    func clearCopies() throws {
        if FileManager.default.fileExists(atPath: bodies.path) { try FileManager.default.removeItem(at: bodies) }
    }

    func copies() throws -> [(id: String, bytes: Int)] {
        guard FileManager.default.fileExists(atPath: bodies.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: bodies, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }.map { url in
                (url.deletingPathExtension().lastPathComponent,
                 try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            }
    }

    private func copyURL(_ id: String) -> URL {
        let name = UUID(uuidString: id)?.uuidString.lowercased() ?? "invalid"
        return bodies.appending(path: name + ".json")
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

