import SwiftUI

/// Inline quick-add bar pinned at the bottom of task lists.
///
/// Tapping the text field (or a single tap on the list's blank area) allows fast
/// single-line task creation; pressing return adds the task and keeps the field
/// focused for rapid entry. A due-date chip surfaces the default that will be
/// applied to the new task and lets the user override it inline for this entry.
/// The expand button opens the full QuickAddView sheet for detailed setup.
struct InlineAddBar: View {

    @Binding var title: String
    var isFocused: FocusState<Bool>.Binding
    /// Human label for the due-date chip, e.g. "Today" or "No date".
    let dueRuleLabel: String
    /// Whether the effective rule sets a date (drives chip highlight).
    let dueRuleIsSet: Bool
    /// Called when the user picks a due-date rule from the chip menu.
    let onPickRule: (DefaultDueDateRule) -> Void
    let onSubmit: () -> Void
    let onExpandTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The due-date chip row only appears while composing, keeping the
            // idle bar minimal.
            if isFocused.wrappedValue {
                dueDateChipRow
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .transition(.opacity)
            }

            HStack(spacing: 10) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.title3)
                    .accessibilityHidden(true)

                TextField("Add a task…", text: $title)
                    .textFieldStyle(.plain)
                    .focused(isFocused)
                    .submitLabel(.done)
                    .onSubmit {
                        onSubmit()
                    }
                    .accessibilityLabel("Quick add task")
                    .accessibilityHint("Type a task title and press return to add it to the current list")

                if !title.isEmpty {
                    Button {
                        onSubmit()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.blue)
                            .font(.title3)
                    }
                    .accessibilityLabel("Add task")
                }

                Button {
                    onExpandTap()
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .accessibilityLabel("Expand to full task creation")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.regularMaterial, in: Rectangle())
        .overlay(alignment: .top) {
            Divider()
        }
        .animation(.easeInOut(duration: 0.2), value: isFocused.wrappedValue)
    }

    /// Row of quick due-date choices surfaced while composing a task.
    private var dueDateChipRow: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(DefaultDueDateRule.allCases) { rule in
                    Button {
                        onPickRule(rule)
                    } label: {
                        Label(rule.displayName,
                              systemImage: rule == .none ? "calendar" : "calendar.badge.plus")
                    }
                }
            } label: {
                Label(dueRuleLabel, systemImage: "calendar")
                    .font(.caption)
                    .fontWeight(.medium)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        (dueRuleIsSet ? Color.blue.opacity(0.15) : Color.secondary.opacity(0.12)),
                        in: Capsule()
                    )
                    .foregroundStyle(dueRuleIsSet ? Color.blue : Color.secondary)
            }
            .accessibilityLabel("Due date for new task")
            .accessibilityValue(dueRuleLabel)
            .accessibilityHint("Choose the due date applied to the task you're adding")

            Spacer()
        }
    }
}
