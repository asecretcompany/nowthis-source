import SwiftUI

@main
struct NowThisWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(PhoneBridge.shared)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { PhoneBridge.shared.reconcileProDeadline() }
                }
        }
    }
}
