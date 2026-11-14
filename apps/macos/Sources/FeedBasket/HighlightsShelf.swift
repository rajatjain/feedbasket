import SwiftUI

struct HighlightsShelf: View {
    @Environment(\.basketStyle) private var style
    @Environment(BasketStore.self) private var store
    @Binding var selection: String?
    @BasketState private var grouping = "Recent"
    @BasketState private var documentType = "All"
    @BasketState private var tag = "All tags"
    @BasketState private var search = ""

    private struct Entry: Identifiable {
        let highlight: Highlight
        let article: Article
        var id: String { highlight.id }
    }

    private var entries: [Entry] {
        (store.library.highlights ?? [:]).values.compactMap { highlight in
            guard let article = store.article(highlight.article_id), article.location != "trash" else { return nil }
            return Entry(highlight: highlight, article: article)
        }.sorted { left, right in
            if left.highlight.created_at == right.highlight.created_at { return left.id < right.id }
            return left.highlight.created_at > right.highlight.created_at
        }
    }

    var body: some View {
        let entries = entries
        let mixed = Set(entries.map { $0.article.isPDF }).count > 1
        let tags = Set(entries.flatMap { $0.article.tags }).sorted()
        let filtered = entries.filter {
            (!mixed || documentType == "All" || $0.article.isPDF == (documentType == "PDFs")) &&
            (!tags.contains(tag) || $0.article.tags.contains(tag)) &&
            (search.isEmpty || $0.highlight.quote.localizedCaseInsensitiveContains(search) || $0.article.title.localizedCaseInsensitiveContains(search))
        }
        let byDocument = Dictionary(grouping: filtered, by: { $0.article.id })
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: BasketTokens.spacing) {
                HStack {
                    Text("Highlights").font(.headline)
                    Spacer()
                    if mixed || !tags.isEmpty {
                        LibraryFilter(groups: (mixed ? [
                            .init(title: "Type", options: ["All", "Articles", "PDFs"], selection: $documentType),
                        ] : []) + (tags.isEmpty ? [] : [
                            .init(title: "Tag", options: ["All tags"] + tags, selection: $tag),
                        ]))
                    }
                }
                Picker("Order", selection: $grouping) {
                    Text("Recent").tag("Recent")
                    Text("By document").tag("By document")
                }.pickerStyle(.segmented).labelsHidden()
                TextField("Search highlights", text: $search).textFieldStyle(.roundedBorder)
            }.padding(BasketTokens.spacing * 1.4)
            Divider()
            if filtered.isEmpty {
                BasketEmpty(title: "No highlights", icon: "highlighter")
            } else {
                List(selection: $selection) {
                    if grouping == "By document" {
                        ForEach(byDocument.keys.sorted { left, right in
                            let a = byDocument[left]?.first?.article.title ?? ""
                            let b = byDocument[right]?.first?.article.title ?? ""
                            return a == b ? left < right : a.localizedStandardCompare(b) == .orderedAscending
                        }, id: \.self) { id in
                            if let group = byDocument[id], let title = group.first?.article.title {
                                Section(title) { ForEach(group) { row($0) } }
                            }
                        }
                    } else {
                        ForEach(filtered) { row($0) }
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .onChange(of: filtered.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .onChange(of: mixed) { if !mixed { documentType = "All" } }
        .onChange(of: tags) { if !tags.contains(tag) { tag = "All tags" } }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(style.color(style.readingSurface))
    }

    private func row(_ entry: Entry) -> some View {
        let highlight = entry.highlight
        return VStack(alignment: .leading, spacing: 5) {
            Label(highlight.quote, systemImage: highlight.style.icon).lineLimit(4)
            HStack {
                Text(entry.article.title).lineLimit(1)
                if let page = highlight.anchor.quads?.first?.page { Text("Page \(page)").fixedSize() }
            }.font(.caption).foregroundStyle(style.color(BasketTokens.muted))
        }
        .padding(.vertical, 5)
        .tag(entry.id)
        .basketSelection(selection == entry.id)
        .contextMenu {
            Button("Remove \(highlight.style.label.lowercased())", role: .destructive) {
                Task { await store.removeHighlight(highlight) }
            }.disabled(!store.canUseAPI)
        }
    }
}
