import SwiftUI

struct FeedCategoryPicker: View {
    @Environment(BasketStore.self) private var store
    @Binding var selection: String?

    var body: some View {
        Picker("Feed Category", selection: $selection) {
            Text("Uncategorized").tag(nil as String?)
            ForEach(store.feedCategories) { category in
                Text(category.name).tag(Optional(category.id))
            }
        }
    }
}

struct MoveFeedCategoryMenu: View {
    @Environment(BasketStore.self) private var store
    let feed: Feed

    var body: some View {
        if !store.feedCategories.isEmpty {
            Menu("Move to Category") {
                Button("Uncategorized") { move(to: nil) }.disabled(feed.category_id == nil)
                ForEach(store.feedCategories) { category in
                    Button(category.name) { move(to: category.id) }.disabled(feed.category_id == category.id)
                }
            }
            .disabled(!store.canUseAPI)
        }
    }

    private func move(to id: String?) {
        Task {
            do { try await store.assignFeedCategory(id, to: [feed.id]) }
            catch is CancellationError {}
            catch { store.report(error, at: .articleList) }
        }
    }
}

struct FeedCategoryActions: View {
    @Environment(BasketStore.self) private var store
    let category: FeedCategory
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("Rename…", systemImage: "pencil", action: rename).disabled(!store.canUseAPI)
        Button("Move Up", systemImage: "arrow.up") { move(up: true) }
            .disabled(!store.canUseAPI || store.feedCategories.first?.id == category.id)
        Button("Move Down", systemImage: "arrow.down") { move(up: false) }
            .disabled(!store.canUseAPI || store.feedCategories.last?.id == category.id)
        Divider()
        Button("Delete…", systemImage: "trash", role: .destructive, action: delete).disabled(!store.canUseAPI)
    }

    private func move(up: Bool) {
        Task {
            do { try await store.moveFeedCategory(category.id, up: up) }
            catch is CancellationError {}
            catch { store.report(error, at: .articleList) }
        }
    }
}

struct FeedCategoryNameSheet: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @BasketState private var name: String
    @BasketState private var saving = false
    @BasketState private var error: String?
    let category: FeedCategory?

    init(category: FeedCategory? = nil) {
        self.category = category
        _name = BasketState(initialValue: category?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BasketTokens.spacing * 1.4) {
            Text(category == nil ? "New Category" : "Rename Category").font(.headline)
            TextField("Category name", text: $name)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(category == nil ? "Create" : "Save Name") {
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await store.saveFeedCategory(name, id: category?.id)
                            dismiss()
                        }
                        catch is CancellationError {}
                        catch { self.error = error.localizedDescription }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || !store.canUseAPI || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          name.unicodeScalars.count > 40 || name == category?.name)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

private struct FeedCategoryDialogs: ViewModifier {
    @Environment(BasketStore.self) private var store
    @Binding var renaming: FeedCategory?
    @Binding var deleting: FeedCategory?

    func body(content: Content) -> some View {
        content
            .sheet(item: $renaming) { FeedCategoryNameSheet(category: $0) }
            .alert("Delete category?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }
            ), presenting: deleting) { category in
                Button("Delete \(category.name)", role: .destructive) {
                    Task {
                        do { try await store.deleteFeedCategory(category.id) }
                        catch is CancellationError {}
                        catch { store.report(error, at: .articleList) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Feeds in this category will move to Uncategorized.")
            }
    }
}

extension View {
    func feedCategoryDialogs(renaming: Binding<FeedCategory?>, deleting: Binding<FeedCategory?>) -> some View {
        modifier(FeedCategoryDialogs(renaming: renaming, deleting: deleting))
    }
}
