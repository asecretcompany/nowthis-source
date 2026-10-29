import SwiftUI

struct WatchListsView: View {
    @Environment(PhoneBridge.self) private var bridge

    var body: some View {
        List {
            Section("Smart Lists") {
                ForEach(WatchSmartList.allCases) { smart in
                    NavigationLink {
                        WatchListDetailView(title: smart.title,
                                            filter: { smart.includes($0, now: .now) })
                    } label: {
                        smartRow(smart)
                    }
                }
            }
            if let lists = bridge.snapshot?.lists, !lists.isEmpty {
                Section("Lists") {
                    ForEach(lists) { list in
                        NavigationLink {
                            WatchListDetailView(title: list.name,
                                                filter: { $0.listID == list.id })
                        } label: {
                            listRow(list)
                        }
                    }
                }
            }
        }
        .navigationTitle("Lists")
    }

    private func smartRow(_ smart: WatchSmartList) -> some View {
        let count = bridge.displayTasks.filter { smart.includes($0, now: .now) }.count
        return HStack {
            Text(smart.title)
            Spacer()
            Text(count, format: .number).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            localized: "watch.list.a11y.taskCount",
            defaultValue: "\(smart.title), \(count) tasks",
            comment: "VoiceOver label for a row on Apple Watch that names a collection and how many tasks are in it. First placeholder is the name (a smart list or a list), second is the count."))
    }

    private func listRow(_ list: WatchListMeta) -> some View {
        HStack {
            Circle().fill(Color(hex: list.colorHex) ?? .gray)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(list.name)
            Spacer()
            Text(list.activeTaskCount, format: .number).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            localized: "watch.list.a11y.taskCount",
            defaultValue: "\(list.name), \(list.activeTaskCount) tasks",
            comment: "VoiceOver label for a row on Apple Watch that names a collection and how many tasks are in it. First placeholder is the name (a smart list or a list), second is the count."))
    }
}
