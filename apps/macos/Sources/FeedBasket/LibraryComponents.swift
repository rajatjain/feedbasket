import SwiftUI

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
    let article: Article
    let archive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: BasketTokens.spacing) {
            Circle().fill(article.read ? .clear : style.accent).frame(width: 6, height: 6).padding(.top, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(article.title)
                    .font(.system(size: 14, weight: article.read ? .medium : .semibold))
                    .lineLimit(3)
                HStack(spacing: 5) {
                    Text(article.source).lineLimit(1).truncationMode(.middle)
                    Text("·").accessibilityHidden(true)
                    Text(article.date, format: .dateTime.month(.abbreviated).day().year())
                        .lineLimit(1).fixedSize()
                    if article.isStarred {
                        Image(systemName: "star.fill").foregroundStyle(style.accent).accessibilityLabel("Starred")
                    }
                }.font(.system(size: 11)).foregroundStyle(style.color(BasketTokens.muted))
                if archive {
                    let sources = [article.feed_ids.isEmpty ? nil : "Subscriptions", article.saved_at == nil ? nil : "Read Later"]
                    Text(sources.compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: BasketTokens.labelSize)).foregroundStyle(style.accent)
                }
                if !article.tags.isEmpty { TagLabel(tag: article.tags.joined(separator: " · ")) }
            }
        }.padding(.vertical, 8)
    }
}

struct FeedMenu: View {
    @Environment(BasketStore.self) private var store
    let feed: Feed
    @BasketState private var confirming: Bool = false

    var body: some View {
        Menu {
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
            Button("Unsubscribe…", role: .destructive) { confirming = true }
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
        .confirmationDialog("Unsubscribe from \(feed.title)?", isPresented: $confirming) {
            Button("Unsubscribe and Delete", role: .destructive) { Task { await store.unsubscribe(feed) } }
        } message: {
            Text("Unstarred articles will be permanently deleted, including copies in Read Later, Archive, Trash, and other feeds. Starred articles will be kept.")
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
