import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryAddButton: View {
    @Environment(\.basketStyle) private var style
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: BasketTokens.spacing * 0.8) {
                Image(systemName: "plus").font(.system(size: BasketTokens.labelSize, weight: .medium))
                Text("Add").font(.system(size: BasketTokens.bodySize, weight: .semibold))
            }
            .foregroundStyle(style.accent)
            .padding(.horizontal, BasketTokens.spacing)
            .frame(height: 26)
            .overlay {
                RoundedRectangle(cornerRadius: BasketTokens.radius)
                    .strokeBorder(style.accent.opacity(0.38), lineWidth: 1)
            }
            .contentShape(.rect(cornerRadius: BasketTokens.radius))
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.roundedRectangle(radius: BasketTokens.radius))
        .fixedSize()
        .help("Add a feed, article or PDF")
    }
}

struct LibraryAddFooter: View {
    @Environment(\.basketStyle) private var style
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(style.color(BasketTokens.line)).frame(height: 1).accessibilityHidden(true)
            LibraryAddButton(action: action)
                .frame(maxWidth: .infinity)
                .padding(.vertical, BasketTokens.spacing * 0.8)
        }
        .background(style.color(style.palette.sidebar))
    }
}

struct AddSheet: View {
    private struct FileChoice {
        let url: URL
        let size: Int
        let id = UUID()
    }

    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    @Environment(\.dismiss) private var dismiss
    let initialFile: URL?
    let tags: [String]
    let didSave: (Article) -> Void
    let didSubscribe: (Feed) -> Void

    @BasketState private var address = ""
    @BasketState private var tagSelection = LibraryTagSelection()
    @BasketState private var feedURL = ""
    @BasketState private var categoryID: String?
    @BasketState private var preview: LinkPreview?
    @BasketState private var file: FileChoice?
    @BasketState private var error: String?
    @BasketState private var previewError: String?
    @BasketState private var looking = false
    @BasketState private var saving = false
    @BasketState private var retry = 0
    @BasketState private var importing = false
    @BasketState private var targeted = false
    @FocusState private var addressFocused: Bool

    private var url: URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = text.contains("://") ? text : "https://" + text
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host(), host.contains("."), url.user() == nil, url.password() == nil,
              url.absoluteString.count <= 4000 else { return nil }
        return url
    }

    private var feed: SubscriptionPreview.Candidate? { preview?.feeds?.first { $0.url == feedURL } }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Add to FeedBasket", systemImage: "plus")
                .font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 5) {
                Text("Paste a link").fontWeight(.semibold)
                TextField("Link URL", text: $address, prompt: Text("https://example.com"))
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onChange(of: address) {
                        if !address.isEmpty { file = nil }
                        preview = nil
                        previewError = nil
                        error = nil
                    }
            }
            if looking {
                ProgressView("Checking link…").controlSize(.small)
            } else if let preview, file == nil {
                linkCard(preview)
            } else if let previewError, file == nil {
                Text(previewError).foregroundStyle(style.color(BasketTokens.muted))
            }

            VStack(spacing: 7) {
                Label(file?.url.lastPathComponent ?? "Drop a PDF here", systemImage: "doc.richtext")
                    .fontWeight(.medium).lineLimit(2)
                if let file {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .foregroundStyle(style.color(BasketTokens.muted))
                }
                HStack {
                    Button(file == nil ? "Choose PDF…" : "Replace PDF…") { importing = true }
                        .buttonStyle(BasketButton())
                    if file != nil { Button("Remove") { file = nil; error = nil }.buttonStyle(.link) }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(12)
            .background(targeted ? style.selection : style.color(BasketTokens.subtle), in: .rect(cornerRadius: BasketTokens.radius))
            .overlay {
                RoundedRectangle(cornerRadius: BasketTokens.radius)
                    .strokeBorder(style.color(BasketTokens.line), style: StrokeStyle(dash: [4, 3]))
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !saving, let url = urls.first, url.isFileURL else { return false }
                choose(url)
                return true
            } isTargeted: { targeted = $0 }

            if file != nil || (preview?.kind == .article || preview?.kind == .pdf) || (previewError != nil && url != nil) {
                LibraryTagPicker(suggestions: tags, selection: $tagSelection)
            }
            if let preview, file == nil, !store.feedCategories.isEmpty,
               (preview.kind == .feed && feed?.already_subscribed != true) ||
               (preview.kind == .article && feed?.already_subscribed != true) {
                FeedCategoryPicker(selection: $categoryID)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
            if !store.canUseAPI { Text("Connect and sign in to add items.").foregroundStyle(.secondary) }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.buttonStyle(BasketButton()).keyboardShortcut(.cancelAction)
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                actions
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(style.color(BasketTokens.surface))
        .disabled(saving)
        .interactiveDismissDisabled(saving)
        .onAppear {
            if let initialFile { choose(initialFile) } else { addressFocused = true }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            do { choose(try result.get()) }
            catch { self.error = error.localizedDescription }
        }
        .task(id: Lookup(address: address, file: file?.id, online: store.canUseAPI, retry: retry)) {
            await lookup()
        }
    }

    private struct Lookup: Equatable {
        let address: String
        let file: UUID?
        let online: Bool
        let retry: Int
    }

    private func linkCard(_ preview: LinkPreview) -> some View {
        let presentation: (String, String) = switch preview.kind {
        case .feed: ("Feed", "dot.radiowaves.left.and.right")
        case .article: ("Article", "doc.text")
        case .pdf: ("PDF link", "doc.richtext")
        case .unsupported: ("Unsupported link", "exclamationmark.circle")
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label(presentation.0, systemImage: presentation.1).foregroundStyle(style.accent)
            if preview.kind == .unsupported {
                Text("This link doesn’t point to an article, feed or PDF. Paste a different link or choose a PDF.")
                    .foregroundStyle(style.color(BasketTokens.muted))
            } else {
                Text(preview.title ?? url?.host() ?? preview.url).font(.headline).lineLimit(2)
                if let description = preview.description, !description.isEmpty {
                    Text(description).foregroundStyle(style.color(BasketTokens.muted)).lineLimit(2)
                }
                if let feeds = preview.feeds, feeds.count > 1 {
                    Picker("Feed", selection: $feedURL) {
                        ForEach(feeds) { item in Text(item.title).tag(item.url) }
                    }
                } else if let feed, preview.kind == .article {
                    Label(feed.title, systemImage: "dot.radiowaves.left.and.right").lineLimit(1)
                }
                if feed?.already_subscribed == true { Text("Already subscribed").foregroundStyle(.secondary) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(style.color(BasketTokens.subtle), in: .rect(cornerRadius: BasketTokens.radius))
    }

    @ViewBuilder private var actions: some View {
        if let file {
            Button("Upload PDF") {
                run {
                    let access = file.url.startAccessingSecurityScopedResource()
                    defer { if access { file.url.stopAccessingSecurityScopedResource() } }
                    let article = try await store.importPDF(file.url, id: file.id, tags: tagSelection.forSave())
                    didSave(article)
                }
            }.buttonStyle(BasketButton(primary: true)).disabled(!store.canUseAPI)
        } else if let preview {
            switch preview.kind {
            case .feed:
                if feed?.already_subscribed != true {
                    Button("Subscribe") { subscribe(preview: preview) }
                        .buttonStyle(BasketButton(primary: true)).disabled(!store.canUseAPI)
                }
            case .article:
                if let feed, feed.already_subscribed != true {
                    Button("Subscribe") { subscribe(preview: preview) }.buttonStyle(BasketButton())
                    Button("Save + subscribe") { save(preview, withFeed: feed.url) }.buttonStyle(BasketButton())
                } else if feed == nil {
                    Button("Follow website") { subscribe(preview: preview, website: true) }.buttonStyle(BasketButton())
                }
                Button("Save article") { save(preview) }.buttonStyle(BasketButton(primary: true))
            case .pdf:
                Button("Save PDF link") { save(preview) }.buttonStyle(BasketButton(primary: true))
            case .unsupported:
                if let url { Button("Open in browser") { NSWorkspace.shared.open(url) }.buttonStyle(BasketButton()) }
            }
        } else if previewError != nil, let url, store.canUseAPI {
            Button("Retry") { retry += 1 }.buttonStyle(BasketButton())
            Menu("Save link as…") {
                Button("Article") { saveAddress(url.absoluteString, title: "", pdf: false) }
                Button("PDF") { saveAddress(url.absoluteString, title: "", pdf: true) }
            }.fixedSize()
        }
    }

    private func choose(_ url: URL) {
        preview = nil
        previewError = nil
        error = nil
        address = ""
        file = nil
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, url.pathExtension.lowercased() == "pdf", let size = values.fileSize else {
                throw APIError(status: 0, detail: "“\(url.lastPathComponent)” isn’t a PDF. Choose a PDF file to upload.")
            }
            guard (1...104_857_600).contains(size) else {
                throw APIError(status: 0, detail: "Choose a nonempty PDF up to 100 MiB.")
            }
            file = FileChoice(url: url, size: size)
        } catch { self.error = error.localizedDescription }
    }

    private func lookup() async {
        guard !Task.isCancelled else { return }
        looking = false
        preview = nil
        previewError = nil
        guard file == nil, store.canUseAPI, !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            guard let url else {
                previewError = "Enter a complete article, feed or PDF URL."
                return
            }
            looking = true
            let result = try await store.previewLink(url)
            try Task.checkCancellation()
            preview = result
            feedURL = result.feeds?.first?.url ?? ""
        } catch {
            guard !Task.isCancelled else { return }
            previewError = error.localizedDescription
        }
        if !Task.isCancelled { looking = false }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard store.canUseAPI, !saving else { return }
        let scope = store.updateScope
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await operation()
                if scope == store.updateScope { dismiss() }
            } catch {
                if scope == store.updateScope { self.error = error.localizedDescription }
            }
        }
    }

    private func subscribe(preview: LinkPreview, website: Bool = false) {
        let choice = website ? nil : feed
        run {
            didSubscribe(try await store.subscribe(url: choice?.url ?? preview.url,
                                                   title: choice?.title ?? preview.title ?? "", website: website, categoryID: categoryID))
        }
    }

    private func save(_ preview: LinkPreview, withFeed feed: String? = nil) {
        saveAddress(preview.url, title: preview.title ?? "", pdf: preview.kind == .pdf, feed: feed)
    }

    private func saveAddress(_ url: String, title: String, pdf: Bool, feed: String? = nil) {
        run {
            let result = try await store.saveLink(url, title: title, tags: tagSelection.forSave(), pdf: pdf, feed: feed, categoryID: categoryID)
            didSave(result.article)
        }
    }
}
