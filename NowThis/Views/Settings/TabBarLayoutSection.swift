import SwiftUI

/// Settings → Tab Bar. Reorder and show/hide the bar's chosen destinations.
///
/// Modelled on `SidebarLayoutSection`, but stores a **single** ordered array of
/// visible tabs rather than a separate order array and hidden set: with tabs
/// that can be added and removed, two keys desynchronise.
///
/// `AppTab.pinned` — Tasks and Settings — is not offered here at all. Both are
/// excluded from `AppTab.customizable`, so they appear in neither list and
/// neither the reorder nor the hide control can reach them.
struct TabBarLayoutSection: View {

    @AppStorage("tabBarVisible") private var visibleTabsJSON = ""
    @State private var visible: [AppTab] = AppTab.defaultVisible

    private var hidden: [AppTab] { AppTab.hidden(given: visible) }

    var body: some View {
        Section {
            ForEach($visible) { $tab in
                let current = tab
                HStack {
                    Label(current.displayName, systemImage: current.icon)
                    Spacer()
                    Button {
                        hide(current)
                    } label: {
                        Image(systemName: "eye")
                    }
                    .buttonStyle(.plain)
                    // Never disabled: every chosen tab can be hidden, the last
                    // one included, which leaves the two pinned tabs alone in
                    // the bar. See `AppTab.canHide(_:from:)` for why a floor
                    // existed at all — it was a storage artefact, not a rule.
                    .foregroundStyle(Color.blue)
                    // Interpolated literal, exactly as `SidebarLayoutSection`
                    // writes it at `SettingsView.swift:613`. This extracts to the
                    // key "Hide %@", which is already in the catalog in all five
                    // languages — reuse it rather than adding a new key.
                    .accessibilityLabel("Hide \(current.displayName)")
                    .accessibilityHint("Removes this from the tab bar. You can add it back here.")
                }
            }
            .onMove(perform: move)

            if !hidden.isEmpty {
                ForEach(hidden) { tab in
                    HStack {
                        Label(tab.displayName, systemImage: tab.icon)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            show(tab)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(!AppTab.canAdd(to: visible))
                        .foregroundStyle(AppTab.canAdd(to: visible) ? Color.blue : Color.secondary)
                        // Extracts to "Show %@", already in the catalog.
                        .accessibilityLabel("Show \(tab.displayName)")
                        .accessibilityHint(AppTab.canAdd(to: visible)
                                           ? "Adds this to the tab bar."
                                           : "The tab bar is full. Hide something before adding this.")
                    }
                }
            }

            Button("Reset to Default") {
                visible = AppTab.defaultVisible
                save()
            }
            .foregroundStyle(.red)
        } header: {
            HStack {
                Text("Tab Bar")
                Spacer()
                EditButton()
                    .font(.caption)
            }
        } footer: {
            // A plain English literal, matching `SidebarLayoutSection`'s footer
            // at `SettingsView.swift:633`. English-as-key entries are the norm
            // here; only dotted lowerCamel keys are treated as *explicit* keys
            // and required to carry a `defaultValue:`.
            Text("Tasks is always the first tab and Settings the last. iOS shows five tabs at most, so you can choose up to three in between.")
        }
        .onAppear { visible = AppTab.decodeVisible(from: visibleTabsJSON) }
    }

    private func move(from source: IndexSet, to destination: Int) {
        visible.move(fromOffsets: source, toOffset: destination)
        save()
    }

    private func hide(_ tab: AppTab) {
        guard AppTab.canHide(tab, from: visible) else { return }
        visible.removeAll { $0 == tab }
        save()
    }

    private func show(_ tab: AppTab) {
        guard AppTab.canAdd(to: visible) else { return }
        visible.append(tab)
        save()
    }

    private func save() {
        visibleTabsJSON = AppTab.encodeVisible(visible)
    }
}
