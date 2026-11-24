import SwiftUI

/// Tracks presentation blockers without taking ownership of any editor or draft.
@MainActor
@Observable
final class TaskLinkPresentationState {
    private var activeTokens: Set<UUID> = []
    var isBlocked: Bool { !activeTokens.isEmpty }

    func setActive(_ active: Bool, token: UUID) {
        guard active != activeTokens.contains(token) else { return }
        if active { activeTokens.insert(token) }
        else { activeTokens.remove(token) }
    }
}

extension EnvironmentValues {
    @Entry var taskLinkPresentations: TaskLinkPresentationState? = nil
}

private struct TaskLinkPresentationBlocker: ViewModifier {
    let isActive: Bool
    @Environment(\.taskLinkPresentations) private var presentations
    @State private var token = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { presentations?.setActive(isActive, token: token) }
            .onChange(of: isActive) { _, active in presentations?.setActive(active, token: token) }
            .onDisappear { presentations?.setActive(false, token: token) }
    }
}

extension View {
    func blocksTaskLinks(isActive: Bool = true) -> some View {
        modifier(TaskLinkPresentationBlocker(isActive: isActive))
    }
}
