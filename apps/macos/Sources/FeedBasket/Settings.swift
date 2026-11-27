import SwiftUI

struct BasketSettings: View {
    @Environment(BasketStore.self) private var store
    @AppStorage(AutoReadPreference.key) private var autoReadDelay = AutoReadPreference.defaultDelay
    @BasketState private var origin: String = ""
    @BasketState private var cutoff: Date = Calendar.current.startOfDay(for: .now)
    @BasketState private var quota: Double = 1.0
    @BasketState private var pdfQuota: Double = 1.0
    @BasketState private var cleanup: Cleanup? = nil

    enum Cleanup: String, Identifiable {
        case allOffline = "Clear all offline copies?"
        case datedOffline = "Remove offline copies before this date?"
        case allBackend = "Remove all backend article bodies?"
        case datedBackend = "Remove backend article bodies before this date?"
        var id: Self { self }
        var backend: Bool { self == .allBackend || self == .datedBackend }
        var dated: Bool { self == .datedOffline || self == .datedBackend }
    }

    var body: some View {
        TabView {
            Form {
                Section("Backend connection") {
                    TextField("Backend API URL", text: $origin)
                    HStack {
                        BasketStatus(online: store.reachable)
                        Spacer()
                        Button("Save URL") { Task { await store.setOrigin(origin) } }
                            .buttonStyle(BasketButton(primary: true))
                    }
                }
            }.formStyle(.grouped).tabItem { Label("Connection", systemImage: "network") }

            BasketAppearanceSettings().tabItem { Label("Appearance", systemImage: "paintpalette") }

            Form {
                Stepper(value: $autoReadDelay, in: AutoReadPreference.delays) {
                    Text("Automatically mark as read after \(autoReadDelay) seconds")
                }
            }.formStyle(.grouped).tabItem { Label("Reading", systemImage: "book") }

            Form {
                Section("Offline Storage") {
                    LabeledContent("Used on this Mac", value: ByteCountFormatter.string(fromByteCount: Int64(store.offlineBytes), countStyle: .file))
                    Text("\(store.offlineCount) offline articles")
                    Text("Read Later and the latest 10 articles per subscription download automatically.")
                        .foregroundStyle(.secondary)
                    DatePicker("Published before", selection: $cutoff, displayedComponents: .date)
                    HStack {
                        Button("Remove by date…") { cleanup = .datedOffline }
                        Button("Clear all…") { cleanup = .allOffline }
                    }.buttonStyle(BasketButton()).disabled(store.offlineCount == 0)
                    Button("Resume automatic downloads") { store.resumeDownloads() }
                        .buttonStyle(BasketButton()).disabled(store.profile == nil)
                }
                Section("Article storage") {
                    if let storage = store.storage {
                        LabeledContent("Article bodies", value: ByteCountFormatter.string(fromByteCount: Int64(storage.used_bytes), countStyle: .file))
                        TextField("Account limit (GB)", value: $quota, format: .number)
                        Button("Save article limit") { saveLimit(quota, pdf: false) }.buttonStyle(BasketButton(primary: true))
                        HStack {
                            Button("Remove by date…") { cleanup = .datedBackend }
                            Button("Remove all…") { cleanup = .allBackend }
                        }.buttonStyle(BasketButton()).disabled(storage.used_bytes == 0)
                    } else {
                        Text("Connect and sign in to view your account’s storage.")
                    }
                }.disabled(!store.canUseAPI)
                if let storage = store.storage, let used = storage.pdf_used_bytes, let limit = storage.pdf_quota_bytes {
                    Section("PDF storage · Cloudflare R2") {
                        LabeledContent("Uploaded PDFs", value: ByteCountFormatter.string(fromByteCount: Int64(used), countStyle: .file))
                        if limit > 0 { ProgressView(value: min(Double(used) / Double(limit), 1)) }
                        Text("PDF links use no R2 storage.").foregroundStyle(.secondary)
                        TextField("PDF limit (GB)", value: $pdfQuota, format: .number)
                        Button("Save PDF limit") { saveLimit(pdfQuota, pdf: true) }.buttonStyle(BasketButton(primary: true))
                    }.disabled(!store.canUseAPI)
                }
            }.formStyle(.grouped).tabItem { Label("Storage", systemImage: "internaldrive") }

            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "list.bullet.rectangle") }
        }
        .padding(BasketTokens.spacing)
        .frame(width: 555, height: 505)
        .modifier(BasketToastOverlay(location: .settings))
        .onAppear { origin = store.origin.absoluteString }
        .task(id: store.canUseAPI) {
            await store.loadStorage()
            if let storage = store.storage { quota = Double(storage.quota_bytes) / 1_000_000_000 }
            if let bytes = store.storage?.pdf_quota_bytes { pdfQuota = Double(bytes) / 1_000_000_000 }
        }
        .alert(item: $cleanup) { item in
            Alert(title: Text(item.rawValue), message: Text("Your article list, tags, and read status are preserved."),
                  primaryButton: .destructive(Text("Remove")) {
                let date = item.dated ? Calendar.current.startOfDay(for: cutoff) : nil
                if item.backend { Task { await store.clearBackendContent(before: date) } }
                else { store.clearOffline(before: date) }
            }, secondaryButton: .cancel())
        }
    }

    private func saveLimit(_ gigabytes: Double, pdf: Bool) {
        guard gigabytes.isFinite, (0...1000).contains(gigabytes) else {
            store.notify("Enter a limit between 0 and 1,000 GB.", icon: "exclamationmark.circle", at: .settings)
            return
        }
        Task { await store.setQuota(Int(gigabytes * 1_000_000_000), pdf: pdf) }
    }
}
