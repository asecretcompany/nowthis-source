import SwiftUI

struct WatchRootView: View {
    @Environment(PhoneBridge.self) private var bridge
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            WatchTodayView()
                .navigationTitle("Today")
                .toolbar {
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
        .sheet(isPresented: $showAdd) { WatchAddView() }
        .onAppear { bridge.activate() }
    }
}
