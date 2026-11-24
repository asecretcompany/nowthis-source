import SwiftUI
import SwiftData

enum FilterRepairCopy {
    static var required: String {
        String(localized: "filter.repair.required", defaultValue: "Review or replace the filter’s rules to see matching tasks.",
               comment: "Shown when a saved filter has rules that cannot be applied.")
    }

    static var unavailable: String {
        String(localized: "filter.repair.unavailable", defaultValue: "This filter is no longer available.",
               comment: "The selected saved filter no longer exists or could not be opened.")
    }

    static var loadFailed: String {
        String(localized: "filter.repair.loadFailed", defaultValue: "Couldn’t load saved filters.",
               comment: "Shown with a Retry button when the app could not read its saved filters.")
    }

    static var invalid: String {
        String(localized: "filter.editor.invalidCriteria", defaultValue: "Choose a match option and complete every rule before saving.",
               comment: "Error when an editor tries to save a filter with incomplete or unsupported criteria.")
    }

    static var changed: String {
        String(localized: "filter.editor.changed", defaultValue: "This filter changed while you were editing. Close and reopen it to review the current rules.",
               comment: "Error when a saved filter was edited or deleted while its editor was open.")
    }

    static var chooseValue: String {
        String(localized: "filter.editor.chooseValue", defaultValue: "Choose an option",
               comment: "Unselected placeholder for an unsupported filter value, comparison, or match option.")
    }

    static var resetRule: String {
        String(localized: "filter.editor.resetRule", defaultValue: "Reset Rule",
               comment: "Resets the comparison and value of an invalid saved filter rule for its currently selected field.")
    }
}

@MainActor
enum SavedFilterStore {
    nonisolated static let didCommit = Notification.Name("SavedFilterStoreDidCommit")

    static func snapshots(in container: ModelContainer) throws -> [SavedFilterSnapshot] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<SavedFilter>(sortBy: [SortDescriptor(\SavedFilter.sortOrder)])
        return try context.fetch(descriptor).map(\.snapshot)
    }

    static func filter(_ id: String, in context: ModelContext) throws -> SavedFilter? {
        var descriptor = FetchDescriptor<SavedFilter>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    static func delete(_ originals: [SavedFilterSnapshot], in container: ModelContainer, errorState: ErrorState?,
                       save: (() throws -> Void)? = nil) {
        let owner = errorState ?? .shared
        let context = ModelContext(container)
        context.autosaveEnabled = false
        do {
            for original in originals {
                guard let current = try filter(original.id, in: context) else { continue }
                guard current.snapshot == original else {
                    owner.show(FilterRepairCopy.changed)
                    return
                }
                context.delete(current)
            }
        } catch {
            ViewPersistence.report(error, to: owner)
            return
        }
        guard context.hasChanges else { owner.dismiss(); return }
        if ViewPersistence.saveOrReport(in: context, errorState: owner, save: save) {
            owner.dismiss()
            publishCommit(in: container)
        } else {
            owner.retryAction = { [weak owner] in
                guard let owner else { return }
                delete(originals, in: container, errorState: owner, save: save)
            }
        }
    }

    static func publishCommit(in container: ModelContainer) {
        NotificationCenter.default.post(name: didCommit, object: CalendarMirrorState.storeKey(container))
    }
}

struct SavedFilterEdits {
    enum Failure: Error { case invalidCriteria, changed }

    let name: String
    let icon: String
    let colorHex: String
    let logic: FilterLogic?
    let rules: [FilterRule]

    static func editableRules(from snapshot: SavedFilterSnapshot) -> [FilterRule] {
        var seen = Set<String>()
        return (snapshot.rules ?? []).map { stored in
            var rule = stored
            if !seen.insert(rule.id).inserted { rule.id = UUID().uuidString }
            rule.value = rule.canonicalValue ?? rule.value
            return rule
        }
    }

    @MainActor
    func save(over original: SavedFilterSnapshot?, in container: ModelContainer, errorState: ErrorState,
              save: (() throws -> Void)? = nil) throws -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let criteria = SavedFilterCriteria(rules: rules, logic: logic) else {
            throw Failure.invalidCriteria
        }
        let bytes = try JSONEncoder().encode(criteria.rules)
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let filter: SavedFilter
        if let original {
            guard let current = try SavedFilterStore.filter(original.id, in: context),
                  current.name == original.name, current.icon == original.icon,
                  current.colorHex == original.colorHex, current.rulesData == original.rulesData,
                  current.logicOperator == original.logicOperator else { throw Failure.changed }
            filter = current
        } else {
            filter = SavedFilter(name: trimmed)
            context.insert(filter)
        }
        filter.name = trimmed
        filter.icon = icon
        filter.colorHex = colorHex
        filter.logicOperator = criteria.logic.rawValue
        filter.rulesData = bytes
        guard ViewPersistence.saveOrReport(in: context, errorState: errorState, save: save) else { return false }
        SavedFilterStore.publishCommit(in: container)
        return true
    }
}

/// Sheet for creating or editing a saved filter preset.
///
/// Provides a form with:
/// - Name, icon picker, color picker
/// - AND/OR logic toggle
/// - Dynamic rule list with field, comparison, value pickers
struct FilterBuilderView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var errorState = ErrorState()
    @Environment(\.dismiss) private var dismiss

    @Query private var taskLists: [TaskList]
    @Query private var tags: [Tag]

    /// Non-nil when editing an existing filter.
    var existingFilter: SavedFilterSnapshot?

    @State private var hasLoaded = false
    @State private var name = ""
    @State private var icon = "line.3.horizontal.decrease.circle"
    @State private var colorHex = "#8E8E93"
    @State private var logic: FilterLogic? = .and
    @State private var rules: [FilterRule] = []

    var body: some View {
        let tagNames = tagNames
        let listNames = listNames
        return NavigationStack {
            Form {
                if let existingFilter, existingFilter.criteria == nil {
                    Text(FilterRepairCopy.required)
                }
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
                        if logic == nil { Text(FilterRepairCopy.chooseValue).tag(nil as FilterLogic?) }
                        ForEach(FilterLogic.allCases, id: \.self) { op in
                            Text(op.displayName).tag(Optional(op))
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Filter logic")
                } header: {
                    Text("Logic")
                } footer: {
                    if let logic {
                        Text(logic == .and ? "Tasks must match ALL rules." : "Tasks must match ANY rule.")
                    }
                }

                // MARK: - Rules
                Section("Rules") {
                    ForEach($rules) { $rule in
                        RuleRow(rule: $rule, tagNames: tagNames, listNames: listNames)
                    }
                    .onDelete { rules.remove(atOffsets: $0) }

                    Button {
                        withAnimation {
                            var rule = FilterRule(field: .status, comparison: .equals, value: "")
                            rule.reset(to: .status)
                            rules.append(rule)
                        }
                    } label: {
                        Label("Add Rule", systemImage: "plus.circle")
                    }
                }
            }
            .environment(\.saveErrorState, errorState)
            .errorBanner(errorState)
            .navigationTitle(existingFilter == nil ? "New Filter" : "Edit Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || rules.isEmpty)
                }
            }
            .onAppear { loadExisting() }
        }
        .blocksTaskLinks()
    }

    // MARK: - Actions

    private var tagNames: [String] { names(from: tags.filter { $0.modelContext != nil }.map(\.name)) }
    private var listNames: [String] {
        let live = TaskListHelpers.liveModels(taskLists, in: modelContext).filter { $0.modelContext != nil }
        return names(from: live.map(\.name))
    }

    private func names(from values: [String]) -> [String] {
        Array(Set(values.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func save() {
        let draft = SavedFilterEdits(name: name, icon: icon, colorHex: colorHex, logic: logic, rules: rules)
        do {
            if try draft.save(over: existingFilter, in: modelContext.container, errorState: errorState) { dismiss() }
        } catch let failure as SavedFilterEdits.Failure {
            errorState.show(failure == .invalidCriteria ? FilterRepairCopy.invalid : FilterRepairCopy.changed)
        } catch {
            ViewPersistence.report(error, to: errorState)
        }
    }

    private func loadExisting() {
        guard !hasLoaded else { return }
        hasLoaded = true
        guard let existing = existingFilter else { return }
        name = existing.name
        icon = existing.icon
        colorHex = existing.colorHex
        logic = existing.logic
        rules = SavedFilterEdits.editableRules(from: existing)
    }
}

// MARK: - Rule Row

private struct RuleRow: View {
    @Binding var rule: FilterRule
    let tagNames: [String]
    let listNames: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Field picker
            Picker("Field", selection: Binding(get: { rule.field }, set: {
                rule.changeField(to: $0, firstTag: tagNames.first, firstList: listNames.first)
            })) {
                ForEach(FilterField.allCases) { field in
                    Label(field.displayName, systemImage: field.icon).tag(field)
                }
            }

            // Comparison picker
            Picker("Comparison", selection: $rule.comparison) {
                if !rule.field.comparisons.contains(rule.comparison) {
                    Text(FilterRepairCopy.chooseValue).tag(rule.comparison)
                }
                ForEach(rule.field.comparisons) { comp in
                    Text(comp.displayName).tag(comp)
                }
            }

            // Value input — contextual
            valueInput

            if !rule.isValid {
                Button { rule.reset(to: rule.field, firstTag: tagNames.first, firstList: listNames.first) } label: {
                    Text(FilterRepairCopy.resetRule)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var valueInput: some View {
        switch rule.field {
        case .status:
            Picker("Value", selection: $rule.value) {
                invalidChoice
                ForEach(TaskStatus.allCases, id: \.rawValue) { status in
                    Text(status.displayName).tag(status.rawValue)
                }
            }

        case .priority:
            Picker("Value", selection: $rule.value) {
                invalidChoice
                ForEach([TaskPriority.high, .medium, .low, TaskPriority.none], id: \.filterToken) { pri in
                    // Display the label, store the token. The tag is written into
                    // SavedFilter.rulesData on disk and must never be a localized string.
                    Text(pri.displayName).tag(pri.filterToken)
                }
            }

        case .tag, .list:
            let choices = rule.field == .tag ? tagNames : listNames
            Picker("Value", selection: $rule.value) {
                invalidChoice
                if rule.canonicalValue != nil, !choices.contains(rule.value) {
                    Text(verbatim: rule.value).tag(rule.value)
                }
                ForEach(choices, id: \.self) { name in
                    Text(verbatim: name).tag(name)
                }
            }

        case .dueDateBefore, .dueDateAfter:
            if let date = rule.dateValue {
                DatePicker("Date", selection: Binding(get: { rule.dateValue ?? date }, set: { rule.setDate($0) }),
                           displayedComponents: .date)
            } else {
                Text(FilterRepairCopy.chooseValue)
            }

        case .hasDueDate:
            Picker("Value", selection: $rule.value) {
                invalidChoice
                Text("Yes").tag("true")
                Text("No").tag("false")
            }
            .pickerStyle(.segmented)

        case .title:
            TextField("Value", text: $rule.value)
        }
    }

    @ViewBuilder
    private var invalidChoice: some View {
        if rule.canonicalValue == nil { Text(FilterRepairCopy.chooseValue).tag(rule.value) }
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
