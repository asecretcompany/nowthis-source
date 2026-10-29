import SwiftUI

struct WatchAddView: View {
    @Environment(PhoneBridge.self) private var bridge
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var dueRule: DefaultDueDateRule = .none
    @State private var priority: TaskPriority = .none
    @State private var showLocked = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Task", text: $text)      // watchOS offers dictation/scribble input
                    .accessibilityLabel("New task")
                    .accessibilityHint("Dictate a task like: buy milk tomorrow at 5 PM.")

                // Both rows are a group VoiceOver can enter, so each option announces its
                // own name and selected state without repeating "Due" on every chip.
                ChoiceRow(header: "Due", options: DefaultDueDateRule.allCases,
                          selection: $dueRule, title: \.displayName)
                ChoiceRow(header: "Priority", options: TaskPriority.allCases,
                          selection: $priority, title: \.displayName)

                Button("Add") {
                    guard bridge.isProUnlocked else { showLocked = true; return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    bridge.add(rawText: trimmed, listID: nil,
                               dueDate: resolvedDueDate(),
                               priorityRaw: priority == .none ? nil : priority.rawValue)
                    dismiss()
                }
                .accessibilityHint("Adds the task. It syncs through your iPhone.")
            }
            .padding(.horizontal, 2)
        }
        .sheet(isPresented: $showLocked) { WatchLockedSheet() }
    }

    /// Resolves the chosen preset to a concrete all-day value *now*, so an edit that sits
    /// queued in `transferUserInfo` still lands on the day the user picked. Built with
    /// `DueDateHelper.dateOnlyValue` so it matches every other all-day due date in the
    /// app and round-trips to `DUE;VALUE=DATE`.
    private func resolvedDueDate() -> Date? {
        guard let offset = dueRule.dayOffset,
              let day = Calendar.current.date(byAdding: .day, value: offset, to: Date())
        else { return nil }
        return DueDateHelper.dateOnlyValue(for: day)
    }
}

/// A wrapping row of single-tap choices, sized for the watch: no crown scrubbing and no
/// second screen, which is the whole reason the add screen offers presets rather than a
/// `DatePicker`.
private struct ChoiceRow<Option: Hashable & Identifiable>: View {
    let header: LocalizedStringKey
    let options: [Option]
    @Binding var selection: Option
    let title: KeyPath<Option, String>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(header)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            // One option per full-width row rather than a row of chips. Four chips across a
            // 46mm watch already truncated "Tomorrow" and "Next Week" in English, and the
            // translations are longer still — "Nächste Woche", "La semaine prochaine". Full
            // width is the only layout that reads in all five languages, and it keeps the
            // single tap that made presets worth having.
            ForEach(options) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(option[keyPath: title])
                            .font(.caption)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .tint(isSelected ? .accentColor : .gray)
                .accessibilityLabel(Text(option[keyPath: title]))
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(header)
    }
}
