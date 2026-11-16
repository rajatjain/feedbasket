import SwiftUI
import UniformTypeIdentifiers

struct FeedSidebarDrag: Codable, Sendable {
    enum Kind: String, Codable, Sendable {
        case feed, category

        var type: UTType {
            switch self {
            case .feed: UTType(exportedAs: "app.feedbasket.reader.subscription", conformingTo: .data)
            case .category: UTType(exportedAs: "app.feedbasket.reader.feed-category", conformingTo: .data)
            }
        }
    }

    let kind: Kind
    let id: String
    let scope: UUID

    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? JSONEncoder().encode(self) else { return provider }
        provider.registerDataRepresentation(forTypeIdentifier: kind.type.identifier, visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

private struct FeedCategoryDrop: ViewModifier {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    @BasketState private var targeted = false
    let categoryID: String?

    private var types: [UTType] {
        let feed = FeedSidebarDrag.Kind.feed.type
        return categoryID == nil ? [feed] : [feed, FeedSidebarDrag.Kind.category.type]
    }

    func body(content: Content) -> some View {
        content
            .background(targeted && store.canUseAPI ? style.accent.opacity(0.14) : .clear,
                        in: .rect(cornerRadius: BasketTokens.radius))
            .onDrop(of: types, isTargeted: $targeted, perform: receive)
    }

    private func receive(_ providers: [NSItemProvider]) -> Bool {
        guard store.canUseAPI, let provider = providers.first,
              let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let item = try? JSONDecoder().decode(FeedSidebarDrag.self, from: data) else { return }
            Task { @MainActor in
                guard item.scope == store.updateScope, store.canUseAPI else { return }
                do {
                    switch item.kind {
                    case .feed:
                        guard let feed = store.library.feeds[item.id], feed.category_id != categoryID else { return }
                        try await store.assignFeedCategory(categoryID, to: [item.id])
                    case .category:
                        let order = store.feedCategories.map(\.id)
                        guard let categoryID, categoryID != item.id,
                              let source = order.firstIndex(of: item.id),
                              let target = order.firstIndex(of: categoryID) else { return }
                        try await store.moveFeedCategory(item.id, up: source > target, relativeTo: categoryID)
                    }
                } catch is CancellationError {}
                catch { store.report(error, at: .articleList) }
            }
        }
        return true
    }
}

extension View {
    @ViewBuilder func feedSidebarDraggable(_ drag: FeedSidebarDrag?) -> some View {
        if let drag { onDrag { drag.itemProvider() } }
        else { self }
    }

    func feedCategoryDropTarget(_ categoryID: String?) -> some View {
        modifier(FeedCategoryDrop(categoryID: categoryID))
    }
}
