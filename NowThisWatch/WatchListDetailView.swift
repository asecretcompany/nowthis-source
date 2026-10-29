import SwiftUI

struct WatchListDetailView: View {
    @Environment(PhoneBridge.self) private var bridge
    @State private var showLocked = false
    let title: String
    let filter: (WatchTask) -> Bool

    private var tasks: [WatchTask] { bridge.displayTasks.filter(filter) }

    var body: some View {
        Group {
            if tasks.isEmpty {
                ContentUnavailableView("No tasks", systemImage: "checkmark.circle")
            } else {
                List(tasks) { task in
                    WatchTaskRow(task: task) {
                        guard bridge.isProUnlocked else { showLocked = true; return }
                        task.isCompleted ? bridge.uncomplete(uid: task.uid)
                                         : bridge.complete(uid: task.uid)
                    }
                }
            }
        }
        .navigationTitle(title)
        .sheet(isPresented: $showLocked) { WatchLockedSheet() }
    }
}
