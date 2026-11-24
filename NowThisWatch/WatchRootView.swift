import SwiftUI

struct WatchRootView: View {
    @Environment(PhoneBridge.self) private var bridge
    @State private var showAdd = false
    @State private var selectedDraft: WatchPendingOperation?

    var body: some View {
        NavigationStack {
            WatchTodayView()
                .navigationTitle("Today")
                .toolbar {
                    if !bridge.delivery.rejectedAdds.isEmpty {
                        ToolbarItem(placement: .bottomBar) {
                            NavigationLink("Drafts") {
                                List {
                                    ForEach(bridge.delivery.rejectedAdds) { draft in
                                        if case .add(let raw, _, _, _) = draft.edit {
                                            Button { selectedDraft = draft } label: {
                                                Text(verbatim: raw).lineLimit(2)
                                            }
                                            .swipeActions {
                                                Button("Delete", role: .destructive) {
                                                    bridge.delivery.discardRejectedAdd(id: draft.id)
                                                }
                                            }
                                        }
                                    }
                                }
                                .navigationTitle("Drafts")
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            WatchListsView()
                        } label: {
                            Image(systemName: "list.bullet")
                        }
                        .accessibilityLabel("Browse lists")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(String(localized: "tasks.a11y.addTask",
                                                   defaultValue: "Add task",
                                                   comment: "VoiceOver label for the toolbar button that opens the watch's new-task sheet. Spoken, not shown — sentence case."))
                    }
                }
        }
        .alert("Repeat", isPresented: Binding(
            get: { bridge.showingUnsupportedRecurrence }, set: { bridge.showingUnsupportedRecurrence = $0 }
        )) {
            Button("OK", role: .cancel) { bridge.showingUnsupportedRecurrence = false }
        } message: {
            Text("NowThis cannot complete tasks with this repeat rule. The task has not been changed.",
                 comment: "Explains a rejected completion of an unsupported imported recurrence rule. The task stays unchanged.")
        }
        .modifier(WatchDeliveryFailureAlert(enabled: !showAdd && selectedDraft == nil))
        .sheet(isPresented: $showAdd) { WatchAddView() }
        .sheet(item: $selectedDraft) { draft in WatchAddView(recovered: draft) }
        .onAppear { bridge.activate() }
    }
}
