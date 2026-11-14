import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class InstalledAppUpdate {
    private static let buildIDKey = "FeedBasketBuildID"
    private let installURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/FeedBasket.app", directoryHint: .isDirectory)
    private let runningBuildID = Bundle.main.object(forInfoDictionaryKey: buildIDKey) as? String
    private let bundleID = Bundle.main.bundleIdentifier
    private var resume = RestartHandoff.take(arguments: ProcessInfo.processInfo.arguments)
    private(set) var isReady = false

    private var isInstalledCopy: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path == installURL.resolvingSymlinksInPath().path
    }

    func check() {
        guard isInstalledCopy, let runningBuildID, let bundleID,
              let data = try? Data(contentsOf: installURL.appending(path: "Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let installedBuildID = info[Self.buildIDKey] as? String else {
            isReady = false
            return
        }
        isReady = installedBuildID != runningBuildID
    }

    func watch() async {
        guard isInstalledCopy else { return }
        while !Task.isCancelled {
            check()
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
        }
    }

    func takeResume() -> RestartSnapshot? {
        defer { resume = nil }
        return resume
    }

    func restart(with snapshot: RestartSnapshot) throws {
        check()
        guard isReady else { return }
        let token = UUID()
        try RestartHandoff.save(snapshot, token: token)
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Launch after AppKit finishes quitting so the two instances never write the library together.
        relaunch.arguments = ["-c", """
            for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
                if ! kill -0 "$1" 2>/dev/null; then
                    exec /usr/bin/open -n -a "$2" --args "$3" "$4"
                fi
                sleep 1
            done
            """, "feedbasket-relaunch", String(ProcessInfo.processInfo.processIdentifier), installURL.path,
            RestartHandoff.argument, token.uuidString]
        do { try relaunch.run() }
        catch {
            RestartHandoff.discard(token)
            throw error
        }
        NSApplication.shared.terminate(nil)
    }
}

struct AppUpdateChip: View {
    @Environment(\.basketStyle) private var style
    @BasketState private var showingActions = false
    @BasketState private var restartFailed = false
    @BasketState private var restarting = false
    let restart: () async throws -> Void

    var body: some View {
        Button {
            showingActions.toggle()
        } label: {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: BasketTokens.bodySize))
                .foregroundStyle(style.accent)
                .frame(width: 25, height: 23)
                .background(style.accent.opacity(0.12), in: .rect(cornerRadius: BasketTokens.radius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Update ready")
        .help("Update ready")
        .popover(isPresented: $showingActions, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: BasketTokens.spacing) {
                Text(restartFailed ? "Couldn’t restart FeedBasket. Try again." : "Restart to use the new build.")
                HStack {
                    Button("Later") { showingActions = false }
                        .buttonStyle(BasketButton())
                        .keyboardShortcut(.cancelAction)
                    Button("Restart") {
                        restarting = true
                        restartFailed = false
                        Task {
                            defer { restarting = false }
                            do { try await restart() }
                            catch {
                                restartFailed = true
                                Diagnostics.write("App restart failed (\(type(of: error)))", level: "WARNING")
                            }
                        }
                    }
                    .buttonStyle(BasketButton(primary: true))
                }
                .disabled(restarting)
            }
            .padding(BasketTokens.spacing * 1.5)
        }
    }
}
