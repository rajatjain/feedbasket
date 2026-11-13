import AppKit
import SwiftUI

@MainActor
enum Diagnostics {
    static let directory = URL.libraryDirectory.appending(path: "Logs/FeedBasket", directoryHint: .isDirectory)
    private static let file = directory.appending(path: "feedbasket.log")
    private static let limit = 1024 * 1024
    private static let clock = ISO8601DateFormatter()

    static func write(_ message: String, level: String = "INFO", source: String = #fileID, line: Int = #line) {
        let name = source.split(separator: "/").last ?? "FeedBasket"
        let data = Data("\(clock.string(from: .now)) \(level) \(name):\(line)] \(message)\n".utf8)
        let files = FileManager.default
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size + data.count > limit {
                for index in (1...2).reversed() {
                    let old = file.appendingPathExtension(String(index))
                    let new = file.appendingPathExtension(String(index + 1))
                    if files.fileExists(atPath: new.path) { try files.removeItem(at: new) }
                    if files.fileExists(atPath: old.path) { try files.moveItem(at: old, to: new) }
                }
                try files.moveItem(at: file, to: file.appendingPathExtension("1"))
            }
            if !files.fileExists(atPath: file.path) {
                try data.write(to: file, options: .atomic)
            } else {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            }
        } catch {
            // Diagnostics should never interrupt the library or its sync.
        }
    }

    static func recent() -> String {
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return current.split(separator: "\n").suffix(200).joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    @BasketState private var entries: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: BasketTokens.spacing) {
            HStack {
                Button("Refresh") { entries = Diagnostics.recent() }
                Button("Copy logs") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entries, forType: .string)
                }.disabled(entries.isEmpty)
                Button("Open log folder") { NSWorkspace.shared.open(Diagnostics.directory) }
            }.buttonStyle(BasketButton())
            ScrollView {
                Text(entries.isEmpty ? "No recent events." : entries)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(BasketTokens.spacing * 2)
        .onAppear { entries = Diagnostics.recent() }
    }
}
