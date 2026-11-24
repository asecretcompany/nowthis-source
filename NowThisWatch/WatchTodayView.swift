import SwiftUI

struct WatchTodayView: View {
    @Environment(PhoneBridge.self) private var bridge
    @State private var showLocked = false

    private var todayTasks: [WatchTask] {
        WatchSmartList.today.filter(bridge.displayTasks)
    }

    var body: some View {
        Group {
            if bridge.snapshot == nil {
                ContentUnavailableView("Open NowThis on your iPhone to sync",
                                       systemImage: "iphone.and.arrow.forward")
            } else if todayTasks.isEmpty && bridge.snapshot?.truncated != true {
                ContentUnavailableView("All clear for today", systemImage: "checkmark.circle")
            } else {
                List {
                    ForEach(todayTasks) { task in
                        WatchTaskRow(task: task) {
                            guard bridge.isProUnlocked else { showLocked = true; return }
                            task.isCompleted ? bridge.uncomplete(uid: task.uid)
                                             : bridge.complete(uid: task.uid)
                        }
                    }
                    if bridge.snapshot?.truncated == true {
                        Text("Some tasks are not shown. Open NowThis on your iPhone to see all tasks.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .sheet(isPresented: $showLocked) { WatchLockedSheet() }
    }
}
