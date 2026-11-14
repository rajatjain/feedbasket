import SwiftUI

struct LibraryFilter: View {
    struct Group: Identifiable {
        let title: String
        let options: [String]
        let selection: Binding<String>
        var firstOptionLabel: String? = nil

        var id: String { title }
    }

    let groups: [Group]

    var body: some View {
        Menu {
            menuItems
        } label: {
            Label(activeCount > 0 ? "Filter (\(activeCount))" : "Filter",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuOrder(.fixed)
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter")
    }

    @ViewBuilder private var menuItems: some View {
        ForEach(groups) { group in
            Section(group.title) {
                Picker(group.title, selection: group.selection) {
                    ForEach(group.options, id: \.self) { option in
                        Text(option == group.options.first ? group.firstOptionLabel ?? option : option)
                            .tag(option)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        if activeCount > 0 {
            Divider()
            Button("Reset filters") {
                for group in groups {
                    if let first = group.options.first { group.selection.wrappedValue = first }
                }
            }
        }
    }

    private var activeCount: Int {
        groups.count { $0.selection.wrappedValue != $0.options.first }
    }
}
