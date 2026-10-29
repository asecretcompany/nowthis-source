import SwiftUI

/// Tells the user, once, that some of their server's lists are in its trash and were therefore
/// not imported.
///
/// Before this existed the lists were imported as ordinary ones, which is how a Murena user
/// ended up with "Aufgaben" three times and "Irgendwann" three times beside lists that appeared
/// exactly once — a calendar deleted and recreated twice leaves two corpses in the trash, and
/// all three carry the same name. Filtering them out fixes that, but silently: someone who can
/// see a list in their server's web interface would just find it missing here. Hence a notice
/// rather than only a filter.
struct TrashedListsNotice: View {
    let lists: [TrashedList]
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(lists) { list in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: list.name)
                                .font(.body)
                            if let deletedAt = list.deletedAt {
                                Text("Deleted \(deletedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("In your server's trash")
                } footer: {
                    Text("These lists were deleted on your server, so they were not added to NowThis. To bring one back, restore it in your server's web interface and sync again.")
                }
            }
            .navigationTitle("Deleted lists skipped")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDismiss)
                }
            }
        }
    }
}

#Preview {
    TrashedListsNotice(
        lists: [
            TrashedList(href: "/c/aufgaben/", name: "Aufgaben",
                        deletedAt: Date(timeIntervalSince1970: 1_755_000_000)),
            TrashedList(href: "/c/irgendwann/", name: "Irgendwann", deletedAt: nil)
        ],
        onDismiss: {}
    )
}
