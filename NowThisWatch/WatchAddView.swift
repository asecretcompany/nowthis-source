import SwiftUI

struct WatchAddView: View {
    @Environment(PhoneBridge.self) private var bridge
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var dueSelection = WatchAddDueSelection()
    @State private var priority: TaskPriority = .none
    @State private var showLocked = false
    let recovered: WatchPendingOperation?
    @State private var recoveredListID: String?

    init(recovered: WatchPendingOperation? = nil) {
        self.recovered = recovered
        if case .add(let raw, let listID, let due, let priorityRaw) = recovered?.edit {
            _text = State(initialValue: raw)
            _recoveredListID = State(initialValue: listID)
            _dueSelection = State(initialValue: WatchAddDueSelection(retainedDate: due))
            _priority = State(initialValue: priorityRaw.map(TaskPriority.fromRFC5545) ?? .none)
        }
    }

    private var missingOriginalList: Bool {
        guard let recoveredListID else { return false }
        return !(bridge.snapshot?.lists.contains { $0.id == recoveredListID } ?? false)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Task", text: $text)      // watchOS offers dictation/scribble input
                    .accessibilityLabel("New task")
                    .accessibilityHint("Dictate a task like: buy milk tomorrow at 5 PM.")

                if recovered != nil {
                    WatchRecoveredListChoices(lists: bridge.snapshot?.lists ?? [],
                        selection: $recoveredListID, missingOriginalList: missingOriginalList)
                    if let originalDueDate = dueSelection.retainedDateForDisplay() {
                        Label {
                            Text(originalDueDate, format: .dateTime.month().day().year())
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                            .accessibilityLabel("Due Date")
                            .accessibilityValue(Text(originalDueDate, format: .dateTime.month().day().year()))
                            .accessibilityAddTraits(.isSelected)
                        Button("Remove Due Date") { dueSelection.removeDate() }
                    }
                }

                // Both rows are a group VoiceOver can enter, so each option announces its
                // own name and selected state without repeating "Due" on every chip.
                ChoiceRow(header: "Due", options: DefaultDueDateRule.allCases,
                          selection: dueSelection.selectedPreset, select: { dueSelection.select($0) }, title: \.displayName)
                ChoiceRow(header: "Priority", options: TaskPriority.allCases,
                          selection: priority, select: { priority = $0 }, title: \.displayName)

                Button("Add") {
                    guard bridge.isProUnlocked else { showLocked = true; return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    let due = dueSelection.resolvedDate()
                    let priorityRaw = priority == .none ? nil : priority.rawValue
                    let accepted: Bool
                    if let recovered {
                        accepted = bridge.delivery.recoverAdd(id: recovered.id, rawText: text,
                            listID: recoveredListID, dueDate: due, priorityRaw: priorityRaw)
                    } else {
                        accepted = bridge.add(rawText: text, listID: nil, dueDate: due, priorityRaw: priorityRaw)
                    }
                    if accepted { dismiss() }
                }
                .disabled(missingOriginalList)
                .accessibilityHint("Adds the task. It syncs through your iPhone.")
            }
            .padding(.horizontal, 2)
        }
        .modifier(WatchDeliveryFailureAlert())
        .sheet(isPresented: $showLocked) { WatchLockedSheet() }
    }
}

/// A wrapping row of single-tap choices, sized for the watch: no crown scrubbing and no
/// second screen, which is the whole reason the add screen offers presets rather than a
/// `DatePicker`.
private struct ChoiceRow<Option: Hashable & Identifiable>: View {
    let header: LocalizedStringKey
    let options: [Option]
    let selection: Option?
    let select: (Option) -> Void
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
                    select(option)
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

/// Explicit tap choices stay legible in the scrolling correction sheet.
private struct WatchRecoveredListChoices: View {
    let lists: [WatchListMeta]
    @Binding var selection: String?
    let missingOriginalList: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("List")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if missingOriginalList {
                Text("Original list unavailable")
                    .font(.caption)
            }
            WatchListChoiceButton(selected: selection == nil, action: { selection = nil }) {
                Text("Default List")
            }
            ForEach(lists) { list in
                WatchListChoiceButton(selected: selection == list.id, action: { selection = list.id }) {
                    Text(verbatim: list.name)
                }
            }
        }
    }
}

private struct WatchListChoiceButton<Title: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder let title: () -> Title

    var body: some View {
        Button(action: action) {
            HStack {
                title()
                    .font(.caption)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(selected ? .accentColor : .gray)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
