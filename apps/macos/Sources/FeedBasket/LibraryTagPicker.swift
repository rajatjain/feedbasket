import SwiftUI

struct LibraryTagSelection {
    var tags: [String] = []
    var query = ""

    static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func forSave() throws -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for name in tags + query.components(separatedBy: ",") {
            let normalized = Self.key(name)
            if !normalized.isEmpty && seen.insert(normalized).inserted { result.append(normalized) }
        }
        guard result.count <= 30, result.allSatisfy({ $0.unicodeScalars.count <= 80 }) else {
            throw APIError(status: 0, detail: "Use up to 30 tags of at most 80 characters.")
        }
        return result
    }

    mutating func pick(_ name: String) throws {
        var next = self
        next.query = name
        tags = try next.forSave()
        query = ""
    }

    struct Option: Identifiable {
        let name: String
        var create = false
        var id: String { LibraryTagSelection.key(name) }
    }

    func options(suggestions: [String], recent: [String]) -> [Option] {
        let selected = Set(tags.map(Self.key))
        let available = Set(suggestions.map(Self.key)).subtracting(selected).filter { !$0.isEmpty }.sorted()
        let search = Self.key(query)
        if search.isEmpty {
            let recent = recent.map(Self.key).filter { available.contains($0) }
            var seen = Set<String>()
            return Array((recent + available).filter { seen.insert($0).inserted }.prefix(3)).map { Option(name: $0) }
        }
        var options = available.filter { $0.contains(search) }.sorted {
            if $0.hasPrefix(search) != $1.hasPrefix(search) { return $0.hasPrefix(search) }
            return $0 < $1
        }.map { Option(name: $0) }
        if !search.contains(",") && !suggestions.contains(where: { Self.key($0) == search }) && !selected.contains(search) {
            options.append(Option(name: search, create: true))
        }
        return options
    }
}

struct LibraryTagPicker: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.basketStyle) private var style
    let suggestions: [String]
    @Binding var selection: LibraryTagSelection
    @FocusState private var focused: Bool
    @BasketState private var open = false
    @BasketState private var active = 0
    @BasketState private var error: String?
    @BasketState private var recent: [String] = []

    private var historyKey: String {
        "recent-tags:" + store.origin.absoluteString + ":" + (store.profile?.id ?? "")
    }

    private var options: [LibraryTagSelection.Option] {
        let libraryTags = store.library.articles.keys.compactMap(store.article).flatMap(\.tags)
        return selection.options(suggestions: suggestions + libraryTags, recent: recent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TagPickerFlow {
                ForEach(selection.tags, id: \.self) { tag in
                    Button {
                        selection.tags.removeAll { $0 == tag }
                        error = nil
                        focused = true
                        open = true
                    } label: {
                        HStack(spacing: 5) {
                            Text(tag).lineLimit(2)
                            Image(systemName: "xmark").font(.system(size: 9))
                        }
                        .font(.system(size: BasketTokens.labelSize))
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .foregroundStyle(style.selectionText)
                        .background(style.selection, in: .rect(cornerRadius: BasketTokens.radius))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove " + tag)
                }
                TextField("Add tags…", text: $selection.query)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 100, idealWidth: 140, maxWidth: 180)
                    .focused($focused)
                    .accessibilityLabel("Find or create a tag")
                    .onSubmit(commit)
                    .onKeyPress(.return) {
                        commit()
                        return .handled
                    }
                    .onKeyPress(.escape) {
                        guard open else { return .ignored }
                        open = false
                        return .handled
                    }
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(style.color(style.readingSurface), in: .rect(cornerRadius: BasketTokens.radius))
            .overlay {
                RoundedRectangle(cornerRadius: BasketTokens.radius)
                    .strokeBorder(focused ? style.accent : style.color(BasketTokens.line))
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { focused = true; open = true }
            if focused && open && !options.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if selection.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(recent.contains(where: { name in options.contains { $0.name == name } }) ? "Recent" : "Your tags")
                            .font(.system(size: BasketTokens.labelSize))
                            .foregroundStyle(style.color(BasketTokens.muted))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                                    Button { pick(option.name) } label: {
                                        Text(option.create ? "+  Create “\(option.name)”" : option.name)
                                            .foregroundStyle(option.create ? style.accent : style.color(BasketTokens.text))
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 7).padding(.vertical, 6)
                                            .background(index == active ? style.selection.opacity(0.5) : .clear,
                                                        in: .rect(cornerRadius: BasketTokens.radius - 1))
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .id(option.id)
                                    .onHover { if $0 { active = index } }
                                }
                            }
                        }
                        .frame(height: min(CGFloat(options.count) * 30, 150))
                        .onChange(of: active) {
                            if options.indices.contains(active) { proxy.scrollTo(options[active].id) }
                        }
                    }
                }
                .padding(3)
                .background(style.color(style.palette.surface), in: .rect(cornerRadius: BasketTokens.radius))
                .overlay {
                    RoundedRectangle(cornerRadius: BasketTokens.radius)
                        .strokeBorder(style.color(BasketTokens.line)).allowsHitTesting(false)
                }
            }
            if let error {
                Text(error).font(.system(size: BasketTokens.labelSize)).foregroundStyle(.red)
            }
        }
        .onChange(of: focused) { if focused { open = true; active = 0 } }
        .onChange(of: selection.query) { open = true; active = 0; error = nil }
        .onChange(of: options.map(\.id)) { active = 0 }
        .task(id: historyKey) { recent = UserDefaults.standard.stringArray(forKey: historyKey) ?? [] }
    }

    private func move(_ direction: Int) {
        guard !options.isEmpty else { return }
        if !open { open = true; active = 0 }
        else { active = (active + direction + options.count) % options.count }
    }

    private func commit() {
        if open && options.indices.contains(active) { pick(options[active].name) }
        else if !selection.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { pick(selection.query) }
    }

    private func pick(_ name: String) {
        do {
            try selection.pick(name)
            let names = name.components(separatedBy: ",").map(LibraryTagSelection.key).filter { !$0.isEmpty }
            recent = Array((names + recent.filter { !names.contains($0) }).prefix(30))
            UserDefaults.standard.set(recent, forKey: historyKey)
            error = nil
            active = 0
            focused = true
            open = true
        } catch { self.error = error.localizedDescription }
    }
}

struct LibraryTagEditor: View {
    @Environment(BasketStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @BasketState private var selection: LibraryTagSelection
    @BasketState private var error: String?
    let save: ([String]) -> Bool

    init(tags: [String], save: @escaping ([String]) -> Bool) {
        _selection = BasketState(wrappedValue: LibraryTagSelection(tags: tags))
        self.save = save
    }

    private var suggestions: [String] {
        Set(store.library.articles.keys.compactMap(store.article).flatMap(\.tags)).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: BasketTokens.spacing) {
            Text("Edit tags").font(.headline)
            LibraryTagPicker(suggestions: suggestions, selection: $selection)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(BasketButton())
                Spacer()
                Button("Save") {
                    do { if save(try selection.forSave()) { dismiss() } }
                    catch { self.error = error.localizedDescription }
                }
                .buttonStyle(BasketButton(primary: true))
            }
        }
        .padding(14).frame(width: 360)
        .onExitCommand { dismiss() }
    }
}

private struct TagPickerFlow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 330, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in layout.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let width = max(width, 1)
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + 5
                rowHeight = 0
            }
            frames.append(CGRect(x: x, y: y, width: size.width, height: size.height))
            x += size.width + 5
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: width, height: y + rowHeight), frames)
    }
}
