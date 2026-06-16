import SwiftUI

/// A pill-shaped filter chip for toggling active filters.
///
/// Adapts appearance based on selection state with smooth animation.
/// Matches Apple's native chip style (e.g., Mail, Photos).
struct FilterChipView: View {

    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            HapticManager.softImpact()
            action()
        }) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isActive ? .white : .primary)
            .modifier(FilterChipBackground(isActive: isActive))
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isActive)
        .accessibilityLabel("\(label) filter")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

}

/// Background for a filter chip: a solid accent fill when active, otherwise
/// Liquid Glass on iOS 26+ (with an ultra-thin material + hairline border
/// fallback on iOS 18–25).
private struct FilterChipBackground: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.background(.tint, in: Capsule())
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule().strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

/// Horizontally scrolling filter bar with multiple filter chips.
struct FilterBar: View {

    @Binding var activeSort: TaskSortOption
    @Binding var sortDirection: SortDirection
    @Binding var showCompleted: Bool
    @Binding var priorityFilter: TaskPriority?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                SortChip(activeSort: $activeSort, sortDirection: $sortDirection)
                CompletedChip(showCompleted: $showCompleted)
                PriorityChips(priorityFilter: $priorityFilter)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Sort Chip

private struct SortChip: View {
    @Binding var activeSort: TaskSortOption
    @Binding var sortDirection: SortDirection

    var body: some View {
        Menu {
            ForEach(TaskSortOption.allCases) { option in
                Button {
                    withAnimation { activeSort = option }
                } label: {
                    Label(option.rawValue, systemImage: option.icon)
                }
            }

            Divider()

            Button {
                withAnimation { sortDirection.toggle() }
            } label: {
                Label(
                    sortDirection == .ascending ? "Descending" : "Ascending",
                    systemImage: sortDirection == .ascending ? "arrow.down" : "arrow.up"
                )
            }
        } label: {
            FilterChipView(
                label: activeSort.rawValue,
                icon: sortDirection.icon,
                isActive: activeSort != .dueDate,
                action: {}
            )
        }
        .accessibilityLabel("Sort by \(activeSort.rawValue), \(sortDirection.rawValue)")
    }
}

// MARK: - Completed Chip

private struct CompletedChip: View {
    @Binding var showCompleted: Bool

    var body: some View {
        FilterChipView(
            label: "Done",
            icon: showCompleted ? "eye.fill" : "eye.slash",
            isActive: showCompleted
        ) {
            withAnimation { showCompleted.toggle() }
        }
    }
}

// MARK: - Priority Chips

private struct PriorityChips: View {
    @Binding var priorityFilter: TaskPriority?

    var body: some View {
        ForEach([TaskPriority.high, .medium, .low], id: \.self) { pri in
            FilterChipView(
                label: pri.displayName,
                icon: pri.systemImageName,
                isActive: priorityFilter == pri
            ) {
                withAnimation {
                    priorityFilter = (priorityFilter == pri) ? nil : pri
                }
            }
        }
    }
}

#Preview {
    VStack {
        FilterBar(
            activeSort: .constant(.dueDate),
            sortDirection: .constant(.ascending),
            showCompleted: .constant(false),
            priorityFilter: .constant(nil)
        )
    }
}
