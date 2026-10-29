import SwiftUI

struct AppIconPickerView: View {
    @Environment(ProEntitlement.self) private var entitlement
    @Environment(AppIconController.self) private var controller
    @State private var showingSupport = false

    var body: some View {
        Form {
            Section {
                ForEach(AppIconCatalog.icons, id: \.id) { icon in
                    let owned = icon.collectionID.map(entitlement.ownedCollectionIDs.contains) ?? true
                    Button {
                        if owned {
                            Task { try? await controller.select(icon, ownedCollectionIDs: entitlement.ownedCollectionIDs) }
                        } else {
                            showingSupport = true
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(icon.previewAssetName).resizable().scaledToFit()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 15))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(icon.title).foregroundStyle(.primary)
                                if icon.collectionID != nil {
                                    Text(verbatim: owned
                                         ? String(localized: "icon.owned", defaultValue: "Owned", comment: "This cosmetic icon collection remains owned after paid subscription expiry.")
                                         : String(localized: "icon.locked", defaultValue: "Available with Supporter", comment: "Cosmetic collection requires Supporter ownership."))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if controller.selectedIconID == icon.id {
                                Image(systemName: "checkmark").accessibilityHidden(true)
                            } else if !owned {
                                Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityHidden(true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .disabled(controller.isChanging || (owned && !controller.supportsAlternateIcons))
                    .accessibilityIdentifier("app-icon-\(icon.id)")
                    .accessibilityAddTraits(controller.selectedIconID == icon.id ? .isSelected : [])
                    .accessibilityHint(owned
                        ? String(localized: "icon.select.hint", defaultValue: "Changes the app icon on your Home Screen.", comment: "Spoken alternate app icon selection hint.")
                        : String(localized: "icon.support.hint", defaultValue: "Opens optional support options. Your current app icon stays selected until you choose an owned design.", comment: "Spoken hint for a locked icon preview. Previewing never changes the Home Screen icon."))
                }
            } footer: {
                Text(verbatim: String(localized: "icon.ownership.hint",
                                      defaultValue: "Optional supporter artwork. Earned collections remain available after subscription expiry.",
                                      comment: "Cosmetic artwork is separate from functional iOS features; paid-period collections remain owned."))
            }
            if AppIconCatalog.icons.contains(where: { icon in
                icon.collectionID.map { !entitlement.ownedCollectionIDs.contains($0) } ?? false
            }) {
                Section {
                    Button {
                        showingSupport = true
                    } label: {
                        Text(verbatim: String(localized: "icon.support.action", defaultValue: "Become a Supporter", comment: "Opens the optional development support purchase options."))
                    }
                    .accessibilityHint(String(localized: "icon.support.hint", defaultValue: "Opens optional support options. Your current app icon stays selected until you choose an owned design.", comment: "Spoken hint for a locked icon preview. Previewing never changes the Home Screen icon."))
                    .accessibilityIdentifier("become-supporter")
                }
            }
            if !controller.supportsAlternateIcons {
                Text(verbatim: String(localized: "icon.unsupported", defaultValue: "App icons cannot be changed on this device.", comment: "Device does not support alternate app icons."))
            }
            if let message = controller.errorMessage {
                Text(verbatim: message).foregroundStyle(.red)
                Button("Retry") {
                    Task { try? await controller.retry(ownedCollectionIDs: entitlement.ownedCollectionIDs) }
                }
                .disabled(controller.isChanging)
            }
        }
        .navigationTitle("App Icon")
        .task { try? await controller.reconcileOwnership(entitlement.ownedCollectionIDs) }
        .sheet(isPresented: $showingSupport) {
            NavigationStack {
                Form { ProUpsellView() }
                    .navigationTitle("Support Development")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showingSupport = false }
                        }
                    }
            }
        }
    }
}
