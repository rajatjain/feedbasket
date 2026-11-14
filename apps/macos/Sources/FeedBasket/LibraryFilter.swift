import SwiftUI

struct LibraryFilter: View {
    struct Group: Identifiable {
        let title: String
        let options: [String]
        let selection: Binding<String>

        var id: String { title }
    }

    let groups: [Group]

    var body: some View {
        Menu {
            ForEach(groups) { group in
                Picker(group.title, selection: group.selection) {
                    ForEach(group.options, id: \.self) { Text($0).tag($0) }
                }.pickerStyle(.menu)
            }
            if activeCount > 0 {
                Divider()
                Button("Reset filters") {
                    for group in groups {
                        if let first = group.options.first { group.selection.wrappedValue = first }
                    }
                }
            }
        } label: {
            Label(activeCount > 0 ? "Filter (\(activeCount))" : "Filter",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter")
    }

    private var activeCount: Int {
        groups.count { $0.selection.wrappedValue != $0.options.first }
    }
}
