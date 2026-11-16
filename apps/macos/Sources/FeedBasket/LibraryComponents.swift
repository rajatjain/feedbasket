import AppKit
import SwiftUI

struct LibraryPaneHeader<Content: View>: View {
    let horizontalInset: CGFloat
    var expandsForContent = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
                .padding(.horizontal, horizontalInset)
                .frame(minHeight: 38, maxHeight: expandsForContent ? nil : 38)
                .zIndex(1)
            Divider()
        }
    }
}

extension View {
    func trackRestartRow(_ id: String, in position: RestartListPosition) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            position.update(id, frame: frame)
        }
        .onDisappear { position.update(id, frame: nil) }
    }

    func trackRestartViewport(in position: RestartListPosition) -> some View {
        onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .global)
        } action: { frame in
            position.viewport = frame
        }
    }
}

struct ArticleBatchBar: View {
    @Environment(\.basketStyle) private var style
    let articles: [Article]
    let clear: () -> Void
    let perform: (ArticleBatchAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(articles.count) selected").fontWeight(.semibold)
                Spacer()
                Button("Clear", action: clear).buttonStyle(.link)
            }
            ViewThatFits(in: .horizontal) {
                actions(.titleAndIcon).fixedSize(horizontal: true, vertical: false)
                actions(.iconOnly)
            }
        }
        .font(.system(size: BasketTokens.labelSize))
        .padding(.horizontal, BasketTokens.spacing)
        .padding(.vertical, 6)
        .background(style.color(BasketTokens.subtle))
    }

    private func actions<Style: LabelStyle>(_ labelStyle: Style) -> some View {
        HStack(spacing: 5) {
            ForEach(ArticleBatchAction.allCases, id: \.self) { action in
                Button(role: action == .trash ? .destructive : nil) {
                    perform(action)
                } label: {
                    Label(action.title, systemImage: action.icon).labelStyle(labelStyle)
                }
                .help(action.title)
                .disabled(!articles.contains(where: action.allows))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct ArticleRow: View {
    @Environment(\.basketStyle) private var style
    @BasketState private var hovering = false
    let article: Article
    let archive: Bool
    let selected: Bool
    let keyboardFocused: Bool
    let perform: (ArticleRowAction) -> Void
    private let actionSize: CGFloat = 23
    private let actionSpacing: CGFloat = 1

    private var readingTime: Text? {
        guard !article.isPDF, let words = article.word_count, words > 0 else { return nil }
        let wordsPerMinute = 150.0
        guard Double(words) >= wordsPerMinute else { return Text("<1 min read") }
        let minutes = Int((Double(words) / wordsPerMinute).rounded())
        return Text("\(minutes) min read")
    }

    var body: some View {
        HStack(alignment: .top, spacing: BasketTokens.spacing) {
            Circle().fill(article.read ? .clear : style.accent).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.system(size: 14, weight: article.read ? .medium : .semibold))
                    .lineLimit(3)
                    .padding(.trailing, CGFloat(ArticleRowAction.allCases.count) * (actionSize + actionSpacing) + 4)
                HStack(spacing: 5) {
                    if article.isPDF {
                        Label(article.pdf?.source == "upload" ? "Uploaded PDF" : "PDF link", systemImage: "doc.richtext")
                            .lineLimit(1)
                    } else {
                        Text(article.source).lineLimit(1).truncationMode(.middle)
                    }
                    Text("·").accessibilityHidden(true)
                    Text(article.date, format: .dateTime.month(.abbreviated).day().year())
                        .lineLimit(1).fixedSize()
                    if let readingTime {
                        Text("·").accessibilityHidden(true)
                        readingTime.lineLimit(1).fixedSize()
                    }
                    if article.isStarred {
                        Image(systemName: "star.fill").foregroundStyle(style.accent).accessibilityLabel("Starred")
                    }
                }.font(.system(size: 11)).foregroundStyle(style.color(BasketTokens.muted))
                if article.isPDF {
                    if article.pdf?.deletion_pending == true {
                        Text("Deleting…").font(.caption).foregroundStyle(.secondary)
                    } else if let position = article.reading_position {
                        let total = article.pdf?.page_count.map { " of \($0)" } ?? ""
                        Text("Page \(position.page)\(total)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if archive {
                    let sources = [article.feed_ids.isEmpty ? nil : "Subscriptions", article.saved_at == nil ? nil : "Read Later"]
                    Text(sources.compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: BasketTokens.labelSize)).foregroundStyle(style.accent)
                }
                if !article.tags.isEmpty { TagLabel(tag: article.tags.joined(separator: " · ")) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: actionSpacing) {
                ForEach(ArticleRowAction.allCases, id: \.self) { action in
                    Button { perform(action) } label: {
                        Label(action.title(for: article), systemImage: action.icon(for: article))
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(ArticleRowButtonStyle(width: actionSize, selected: selected))
                    .help(action.title(for: article))
                    .disabled(!action.allows(article))
                }
            }
            .fixedSize()
            .opacity(hovering || keyboardFocused ? 1 : 0)
            .allowsHitTesting(hovering || keyboardFocused)
            .accessibilityHidden(!hovering && !keyboardFocused)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            swipeButton(.readStatus)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            swipeButton(.archive)
            swipeButton(.star)
        }
    }

    @ViewBuilder private func swipeButton(_ action: ArticleRowAction) -> some View {
        if action.allows(article) {
            Button { perform(action) } label: {
                Label(action.title(for: article), systemImage: action.icon(for: article))
            }
            .tint(style.accent)
        }
    }
}

private struct ArticleRowButtonStyle: ButtonStyle {
    @Environment(\.basketStyle) private var style
    @Environment(\.isEnabled) private var enabled
    @BasketState private var hovering = false
    let width: CGFloat
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: width, height: 20)
            .foregroundStyle(selected ? style.selectionText : style.color(BasketTokens.text))
            .background((hovering || configuration.isPressed) && enabled
                        ? (selected ? style.selectionText.opacity(0.09) : style.color(BasketTokens.subtle)) : .clear,
                        in: .rect(cornerRadius: BasketTokens.radius))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

struct SidebarRowWithActions<Content: View, Actions: View>: View {
    @BasketState private var hovering = false
    let menuTitle: String
    var showsActions = true
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 6) {
            content()
            if showsActions {
                Menu {
                    actions()
                } label: {
                    Label(menuTitle, systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                        .frame(width: 20, height: 16)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(menuTitle)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityHidden(!hovering)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            if showsActions { actions() }
        }
    }
}

struct SidebarFeedRow: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    let feed: Feed
    let selected: Bool
    let hasUnread: Bool
    let rename: () -> Void
    let unsubscribe: () -> Void

    var body: some View {
        SidebarRowWithActions(menuTitle: "Feed actions") {
            Label {
                Text(feed.title)
                    .fontWeight(hasUnread ? .semibold : .regular)
                    .lineLimit(1)
            } icon: {
                Image(systemName: feed.isWebsite ? "globe" : "newspaper")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityValue(hasUnread ? "Unread articles" : "")

            if hasUnread {
                Circle()
                    .fill(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(style.accent))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        } actions: {
            actions
        }
    }

    @ViewBuilder private var actions: some View {
        Button("Rename", action: rename)
            .disabled(!store.canUseAPI)
        MoveFeedCategoryMenu(feed: feed)
        Button("Mark All as Read") { store.markFeedAsRead(feed) }
            .disabled(!hasUnread)
        Divider()
        Button("Unsubscribe…", role: .destructive, action: unsubscribe)
            .disabled(!store.canUseAPI)
    }
}

struct FeedMenu: View {
    @Environment(BasketStore.self) private var store
    let feed: Feed
    let rename: () -> Void
    let unsubscribe: () -> Void

    var body: some View {
        Menu {
            Button("Rename", action: rename)
            MoveFeedCategoryMenu(feed: feed)
            Button("Refresh now") { Task { await store.feedAction(feed, path: "refresh") } }
            Menu("Refresh interval") {
                ForEach([0, 15, 30, 60, 360, 1440], id: \.self) { value in
                    Button(value == 0 ? "Server default" : "\(value) minutes") {
                        Task { await store.setInterval(value, feed: feed) }
                    }
                }
            }
            if !feed.isWebsite && feed.initial_done && feed.history_end {
                Button("Check for older articles") {
                    Task { await store.feedAction(feed, path: "older", recheck: true) }
                }
            }
            Divider()
            Button("Unsubscribe…", role: .destructive, action: unsubscribe)
        } label: {
            Label("Feed settings", systemImage: "ellipsis.circle")
                .labelStyle(.iconOnly)
                .font(.system(size: 15))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Feed settings")
        .disabled(!store.canUseAPI)
    }
}

struct RenameFeedSheet: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @BasketState private var name: String
    @BasketState private var saving = false
    @BasketState private var error: String?
    let feed: Feed

    init(feed: Feed) {
        self.feed = feed
        _name = BasketState(initialValue: feed.title)
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool {
        !saving && store.canUseAPI && !trimmedName.isEmpty && trimmedName.unicodeScalars.count <= 500
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename").font(.headline)
            FeedNameField(name: $name, enabled: !saving) {
                if canSave { save(trimmedName) }
            }
            .frame(height: 24)
            if let error {
                Text(error).foregroundStyle(.red)
            }
            HStack {
                Button("Use Publisher Name") { save(nil) }
                    .disabled(saving || !store.canUseAPI || store.library.feeds[feed.id]?.custom_title == nil)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(saving)
                Button("Save") { save(trimmedName) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 400)
        .interactiveDismissDisabled(saving)
    }

    private func save(_ title: String?) {
        guard !saving else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await store.renameFeed(feed, title: title)
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct FeedNameField: NSViewRepresentable {
    @Binding var name: String
    let enabled: Bool
    let submit: () -> Void

    func makeNSView(context: Context) -> NameTextField {
        let field = NameTextField(string: name)
        field.placeholderString = "Feed name"
        field.setAccessibilityLabel("Feed name")
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NameTextField, context: Context) {
        context.coordinator.parent = self
        field.isEnabled = enabled
        if field.stringValue != name { field.stringValue = name }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class NameTextField: NSTextField {
        private var selectedInitialName = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, !selectedInitialName else { return }
            selectedInitialName = true
            DispatchQueue.main.async { [weak self] in self?.selectText(nil) }
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FeedNameField

        init(_ parent: FeedNameField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.name = field.stringValue }
        }

        @MainActor
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            parent.name = textView.string
            parent.submit()
            return true
        }
    }
}

struct FeedHistoryFooter: View {
    @Environment(BasketStore.self) private var store
    let feed: Feed
    @BasketState private var loading = false

    var body: some View {
        VStack(spacing: BasketTokens.spacing) {
            if let error = feed.error {
                Text(error).foregroundStyle(.secondary)
            }
            if !feed.isWebsite && feed.initial_done {
                if feed.history_end {
                    Text("No more articles in this feed.").foregroundStyle(.secondary)
                } else {
                    Button(loading ? "Loading…" : "Load older articles") {
                        loading = true
                        Task {
                            defer { loading = false }
                            await store.feedAction(feed, path: "older")
                        }
                    }
                    .buttonStyle(BasketButton())
                    .disabled(loading || !store.canUseAPI)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
}
