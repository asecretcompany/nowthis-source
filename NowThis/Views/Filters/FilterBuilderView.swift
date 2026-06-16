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
                            Text(op.label).tag(op)
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
                    Label(field.rawValue, systemImage: field.icon).tag(field)
                }
            }

            // Comparison picker
            Picker("Comparison", selection: $rule.comparison) {
                ForEach(rule.field.comparisons) { comp in
                    Text(comp.rawValue).tag(comp)
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
                ForEach([TaskPriority.high, .medium, .low, TaskPriority.none], id: \.displayName) { pri in
                    Text(pri.displayName).tag(pri.displayName)
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

    private let icons = [
        "line.3.horizontal.decrease.circle",
        "star.fill",
        "heart.fill",
        "bolt.fill",
        "flame.fill",
        "leaf.fill",
        "briefcase.fill",
        "house.fill",
        "person.fill",
        "tag.fill",
        "flag.fill",
        "bell.fill"
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(icons, id: \.self) { icon in
                    iconButton(icon)
                }
            }
        }
    }

    private func iconButton(_ icon: String) -> some View {
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
        .accessibilityLabel(icon)
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
