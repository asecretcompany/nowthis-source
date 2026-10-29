import SwiftUI
import SwiftData

/// Sheet for creating or editing a saved filter preset.
///
/// Provides a form with:
/// - Name, icon picker, color picker
/// - AND/OR logic toggle
/// - Dynamic rule list with field, comparison, value pickers
struct FilterBuilderView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var taskLists: [TaskList]
    @Query private var tags: [Tag]

    /// Non-nil when editing an existing filter.
    var existingFilter: SavedFilter?

    @State private var name = ""
    @State private var icon = "line.3.horizontal.decrease.circle"
    @State private var colorHex = "#8E8E93"
    @State private var logic: FilterLogic = .and
    @State private var rules: [FilterRule] = []

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - Identity
                Section("Name & Appearance") {
                    TextField("Filter name", text: $name)
                    IconPicker(selected: $icon)
                    ColorPicker(
                        "Color",
                        selection: Binding(
                            get: { Color(hex: colorHex) ?? .gray },
                            set: { colorHex = $0.hexString }
                        )
                    )
                }

                // MARK: - Logic
                Section {
                    Picker("Match", selection: $logic) {
                        ForEach(FilterLogic.allCases, id: \.self) { op in
                            Text(op.displayName).tag(op)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Filter logic")
                } header: {
                    Text("Logic")
                } footer: {
                    Text(logic == .and
                         ? "Tasks must match ALL rules."
                         : "Tasks must match ANY rule.")
                }

                // MARK: - Rules
                Section("Rules") {
                    ForEach($rules) { $rule in
                        RuleRow(rule: $rule, tags: tags, lists: taskLists)
                    }
                    .onDelete { rules.remove(atOffsets: $0) }

                    Button {
                        withAnimation {
                            rules.append(FilterRule(
                                field: .status,
                                comparison: .equals,
                                value: TaskStatus.needsAction.rawValue
                            ))
                        }
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                }
            }
            .navigationTitle(existingFilter == nil ? "New Filter" : "Edit Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || rules.isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
    }

    // MARK: - Actions

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !rules.isEmpty else { return }

        if let existing = existingFilter {
            existing.name = trimmed
            existing.icon = icon
            existing.colorHex = colorHex
            existing.logic = logic
            existing.rules = rules
        } else {
            let filter = SavedFilter(
                name: trimmed,
                icon: icon,
                colorHex: colorHex,
                rules: rules,
                logicOperator: logic
            )
            modelContext.insert(filter)
        }

        try? modelContext.save()
        dismiss()
    }

    private func loadExisting() {
        guard let existing = existingFilter else { return }
        name = existing.name
        icon = existing.icon
        colorHex = existing.colorHex
        logic = existing.logic
        rules = existing.rules
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    @Binding var rule: FilterRule
    let tags: [Tag]
    let lists: [TaskList]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Field picker
            Picker("Field", selection: $rule.field) {
                ForEach(FilterField.allCases) { field in
                    Label(field.displayName, systemImage: field.icon).tag(field)
                }
            }

            // Comparison picker
            Picker("Comparison", selection: $rule.comparison) {
                ForEach(rule.field.comparisons) { comp in
                    Text(comp.displayName).tag(comp)
                }
            }

            // Value input — contextual
            valueInput
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var valueInput: some View {
        switch rule.field {
        case .status:
            Picker("Value", selection: $rule.value) {
                ForEach(TaskStatus.allCases, id: \.rawValue) { status in
                    Text(status.displayName).tag(status.rawValue)
                }
            }

        case .priority:
            Picker("Value", selection: $rule.value) {
                ForEach([TaskPriority.high, .medium, .low, TaskPriority.none], id: \.filterToken) { pri in
                    // Display the label, store the token. The tag is written into
                    // SavedFilter.rulesData on disk and must never be a localized string.
                    Text(pri.displayName).tag(pri.filterToken)
                }
            }

        case .tag:
            if tags.isEmpty {
                Text("No tags available").foregroundStyle(.secondary)
            } else {
                Picker("Value", selection: $rule.value) {
                    ForEach(tags) { tag in
                        Text(tag.name).tag(tag.name)
                    }
                }
            }

        case .list:
            Picker("Value", selection: $rule.value) {
                ForEach(lists) { list in
                    Text(list.name).tag(list.name)
                }
            }

        case .dueDateBefore, .dueDateAfter:
            DatePicker(
                "Date",
                selection: Binding(
                    get: {
                        ISO8601DateFormatter().date(from: rule.value) ?? Date()
                    },
                    set: {
                        rule.value = ISO8601DateFormatter().string(from: $0)
                    }
                ),
                displayedComponents: .date
            )

        case .hasDueDate:
            Picker("Value", selection: $rule.value) {
                Text("Yes").tag("true")
                Text("No").tag("false")
            }
            .pickerStyle(.segmented)

        case .title:
            TextField("Value", text: $rule.value)
        }
    }
}

// MARK: - Icon Picker

private struct IconPicker: View {
    @Binding var selected: String

    /// SF Symbol name plus the word VoiceOver should say.
    ///
    /// The symbol name is persisted in `SavedFilter.icon` and must never be localized; the label
    /// is display-only. Before this, `.accessibilityLabel(icon)` read the raw symbol name aloud —
    /// a VoiceOver user heard "line dot three dot horizontal dot decrease dot circle" and had no
    /// way to tell the twelve icons apart.
    private let icons: [(symbol: String, label: String)] = [
        ("line.3.horizontal.decrease.circle",
         String(localized: "filter.icon.filter", defaultValue: "Filter", comment: "VoiceOver name for the funnel icon in the saved-filter icon picker.")),
        ("star.fill", String(localized: "filter.icon.star", defaultValue: "Star", comment: "VoiceOver name for the star icon in the saved-filter icon picker.")),
        ("heart.fill", String(localized: "filter.icon.heart", defaultValue: "Heart", comment: "VoiceOver name for the heart icon in the saved-filter icon picker.")),
        ("bolt.fill", String(localized: "filter.icon.bolt", defaultValue: "Lightning bolt", comment: "VoiceOver name for the lightning-bolt icon in the saved-filter icon picker.")),
        ("flame.fill", String(localized: "filter.icon.flame", defaultValue: "Flame", comment: "VoiceOver name for the flame icon in the saved-filter icon picker.")),
        ("leaf.fill", String(localized: "filter.icon.leaf", defaultValue: "Leaf", comment: "VoiceOver name for the leaf icon in the saved-filter icon picker.")),
        ("briefcase.fill", String(localized: "filter.icon.briefcase", defaultValue: "Briefcase", comment: "VoiceOver name for the briefcase icon in the saved-filter icon picker.")),
        ("house.fill", String(localized: "filter.icon.house", defaultValue: "House", comment: "VoiceOver name for the house icon in the saved-filter icon picker.")),
        ("person.fill", String(localized: "filter.icon.person", defaultValue: "Person", comment: "VoiceOver name for the person icon in the saved-filter icon picker.")),
        ("tag.fill", String(localized: "filter.icon.tag", defaultValue: "Tag", comment: "VoiceOver name for the tag icon in the saved-filter icon picker.")),
        ("flag.fill", String(localized: "filter.icon.flag", defaultValue: "Flag", comment: "VoiceOver name for the flag icon in the saved-filter icon picker.")),
        ("bell.fill", String(localized: "filter.icon.bell", defaultValue: "Bell", comment: "VoiceOver name for the bell icon in the saved-filter icon picker.")),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(icons, id: \.symbol) { entry in
                    iconButton(entry.symbol, label: entry.label)
                }
            }
        }
    }

    private func iconButton(_ icon: String, label: String) -> some View {
        let isSelected = selected == icon
        return Button {
            selected = icon
        } label: {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(width: 36, height: 36)
                .background(
                    Circle().fill(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Color Extension

extension Color {
    /// Hex string representation.
    var hexString: String {
        let components = UIColor(self).cgColor.components ?? [0, 0, 0]
        let r = Int((components[safe: 0] ?? 0) * 255)
        let g = Int((components[safe: 1] ?? 0) * 255)
        let b = Int((components[safe: 2] ?? 0) * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
