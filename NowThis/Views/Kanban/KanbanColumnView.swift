import SwiftUI
import SwiftData

/// A single column in the Kanban board representing a `TaskStatus`.
///
/// Displays a colored header with task count and a scrollable list of
/// `KanbanCardView` items. Drop highlighting is managed by the parent
/// `KanbanBoardView` which owns the drop destination.
struct KanbanColumnView: View {

    /// Names the space each column's cards report their position in. The board
    /// applies it to the same view as its drop destination, so a drop's location
    /// and a card's position can be compared directly.
    nonisolated static let coordinateSpace = "kanbanColumn"

    let status: TaskStatus
    /// The column's cards in board order — see `KanbanReorder.columnOrder`.
    let tasks: [TaskItem]
    /// Where each card is, read by the board when something is dropped here.
    let cardFrames: KanbanCardFrames
    /// Whether a dragged card is over this column, so the column shows it will
    /// take the drop.
    let isDropTarget: Bool
    /// Carries out a Move action chosen from a card's menu or its VoiceOver actions.
    let onMove: (_ taskID: String, _ move: KanbanReorder.Move) -> Void

    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var syncScheduler: SyncScheduler
    /// Captured when Move to List… is chosen, so the sheet never reads the card's model.
    @State private var moveRequest: MoveToListRequest?

    var body: some View {
        VStack(spacing: 0) {
            // Column header
            columnHeader

            // Task cards
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { position, task in
                        // Snapshot to a value here, while `task` is a live model
                        // delivered by the parent's @Query. The card never holds
                        // the model, so a later deferred re-layout can't
                        // dereference a row a background sync has deleted.
                        if let data = KanbanCardData(task: task) {
                            // The id is copied for the same reason: the closures
                            // below run later, and must not read the model then.
                            let taskID = task.id
                            let moveRequestForCard = MoveToListRequest(task: task)
                            let canMoveToList = MoveDestinations.canMove(task)
                            NavigationLink(value: task) {
                                KanbanCardView(data: data)
                            }
                            .buttonStyle(.plain)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.frame(in: .named(Self.coordinateSpace)).midY
                            } action: { midY in
                                cardFrames.record(midY, for: taskID)
                            }
                            .onDisappear {
                                cardFrames.record(nil, for: taskID)
                            }
                            .draggable(taskID) {
                                // Drag preview
                                KanbanCardView(data: data)
                                    .frame(width: 240)
                                    .opacity(0.85)
                            }
                            .contextMenu {
                                moveButtons(availableMoves(forCardAt: position), taskID: taskID)
                                Divider()
                                moveToListButton(moveRequestForCard, enabled: canMoveToList)
                            }
                            // Every move, always, rather than the menu's
                            // position-aware set. Actions refreshed when a card's
                            // move changed how many it offered but not when it
                            // changed which: a card moved from the bottom to the
                            // top kept offering Move Up and Move to Top, and no
                            // way down (iOS 27 simulator). A move past an end
                            // does nothing.
                            .accessibilityActions {
                                moveButtons(KanbanReorder.Move.allCases, taskID: taskID)
                                if canMoveToList {
                                    moveToListButton(moveRequestForCard, enabled: true)
                                }
                            }
                        }
                    }

                    // Empty column hint
                    if tasks.isEmpty {
                        Text("Drop tasks here")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGroupedBackground))
        )
        // The drop target used to show nothing, so a release gave no warning of
        // where the card would land, or that it would land at all.
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .fill(columnColor.opacity(0.08))
                .strokeBorder(columnColor, lineWidth: 2)
                .opacity(isDropTarget ? 1 : 0)
                .allowsHitTesting(false)
        }
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
        .sheet(item: $moveRequest) { request in
            MoveToListSheet(request: request) { listID in
                guard MoveDestinations.perform(taskID: request.taskID, toListID: listID, in: modelContext) else { return }
                syncScheduler.syncAfterChange(modelContext: modelContext)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(
            localized: "kanban.column.a11y",
            defaultValue: "\(status.displayName) column, \(tasks.count) tasks",
            comment: "VoiceOver label for a board column. First placeholder is the already-localized status name, second is how many tasks are in the column."))
    }

    // MARK: - Move Actions

    /// The moves that make sense for the card at `position`: none past either end.
    private func availableMoves(forCardAt position: Int) -> [KanbanReorder.Move] {
        KanbanReorder.Move.allCases.filter {
            KanbanReorder.targetIndex(for: $0, from: position, count: tasks.count) != nil
        }
    }

    /// Buttons for the context menu and the VoiceOver actions, so a VoiceOver
    /// user can reorder a column without the drag they cannot perform.
    private func moveButtons(_ moves: [KanbanReorder.Move], taskID: String) -> some View {
        ForEach(moves, id: \.self) { move in
            Button {
                onMove(taskID, move)
            } label: {
                moveLabel(move)
            }
        }
    }

    /// Moves the card's task to another list. Not a `KanbanReorder.Move`: it
    /// leaves the board's list scope rather than reordering a column.
    private func moveToListButton(_ request: MoveToListRequest?, enabled: Bool) -> some View {
        Button {
            moveRequest = request
        } label: {
            Label {
                Text("Move to List…", comment: "Context-menu item on a task that opens a picker to move the task, with its subtasks, to a different list.")
            } icon: {
                Image(systemName: "folder")
            }
        }
        .disabled(!enabled || request == nil)
    }

    private func moveLabel(_ move: KanbanReorder.Move) -> Label<Text, Image> {
        switch move {
        case .top:
            Label(String(localized: "kanban.card.move.top", defaultValue: "Move to Top",
                         comment: "Board card context menu item and VoiceOver action: moves the card to the top of its column. Action button — use the platform's button mood."),
                  systemImage: "arrow.up.to.line")
        case .up:
            Label(String(localized: "kanban.card.move.up", defaultValue: "Move Up",
                         comment: "Board card context menu item and VoiceOver action: moves the card up one place in its column. Action button — use the platform's button mood."),
                  systemImage: "arrow.up")
        case .down:
            Label(String(localized: "kanban.card.move.down", defaultValue: "Move Down",
                         comment: "Board card context menu item and VoiceOver action: moves the card down one place in its column. Action button — use the platform's button mood."),
                  systemImage: "arrow.down")
        case .bottom:
            Label(String(localized: "kanban.card.move.bottom", defaultValue: "Move to Bottom",
                         comment: "Board card context menu item and VoiceOver action: moves the card to the bottom of its column. Action button — use the platform's button mood."),
                  systemImage: "arrow.down.to.line")
        }
    }

    // MARK: - Column Header

    private var columnHeader: some View {
        HStack(spacing: 8) {
            // Colored accent bar
            RoundedRectangle(cornerRadius: 2)
                .fill(columnColor)
                .frame(width: 4, height: 20)
                .accessibilityHidden(true)

            // Status name
            Text(status.displayName)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)

            Spacer()

            // Task count badge
            Text(tasks.count, format: .number)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(columnColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(columnColor.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Colors

    var columnColor: Color {
        switch status {
        case .needsAction: return .blue
        case .inProcess: return .orange
        case .completed: return .green
        case .cancelled: return .gray
        }
    }
}

/// The vertical middle of each card on screen, in its column's coordinate space.
///
/// A reference type the board holds but does not observe, deliberately. Cards
/// report their position on every frame of a scroll, and writing that into view
/// state would re-render the column each frame. It is read only on a drop.
@MainActor
final class KanbanCardFrames {
    private var midYs: [String: CGFloat] = [:]

    func midY(of taskID: String) -> CGFloat? {
        midYs[taskID]
    }

    /// Records where a card is, or forgets it when it leaves the screen.
    func record(_ midY: CGFloat?, for taskID: String) {
        midYs[taskID] = midY
    }
}
