import SwiftUI
import SwiftData

/// Presents the user with two account mode options: Vault (local) or Nextcloud (synced).
///
/// Each option is displayed as a prominent card with an icon, title, and description.
/// Vault Mode creates a local account immediately; Nextcloud navigates to the
/// server setup form.
struct AccountTypeChooserView: View {

    @Environment(\.modelContext) private var modelContext
    @State private var vaultCreated = false
    @State private var showNextcloudSetup = false
    @State private var cardsAppeared = false

    var body: some View {
        VStack(spacing: 24) {
            HeaderSection()

            VStack(spacing: 16) {
                VaultCard(appeared: cardsAppeared) {
                    createVaultAccount()
                }

                NextcloudCard(appeared: cardsAppeared) {
                    showNextcloudSetup = true
                }
            }
            .padding(.horizontal, 20)

            Spacer()

            FooterNote()
        }
        .padding(.top, 20)
        .navigationTitle("Choose Mode")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showNextcloudSetup) {
            AccountSetupView()
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.5).delay(0.2)) {
                cardsAppeared = true
            }
        }
    }

    private func createVaultAccount() {
        let manager = AccountManager(modelContext: modelContext)
        do {
            try manager.createVaultAccount()
            vaultCreated = true
        } catch {
            // Error handling will be enhanced in Phase 5
        }
    }
}

// MARK: - Sub-views

private struct HeaderSection: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("How would you like to use NowThis?")
                .font(.title3)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)

            Text("You can switch anytime in Settings.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
    }
}

private struct VaultCard: View {
    let appeared: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                IconBadge(
                    systemName: "lock.shield.fill",
                    gradient: [.purple, .indigo]
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Vault Mode")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Keep everything on this device. Private. No account needed.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .glassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vault Mode. Keep everything on this device. Private. No account needed.")
        .accessibilityAddTraits(.isButton)
    }
}

private struct NextcloudCard: View {
    let appeared: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                IconBadge(
                    systemName: "cloud.fill",
                    gradient: [.blue, .cyan]
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Nextcloud")
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text("Sync your tasks across devices with your Nextcloud server.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
            .glassCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Nextcloud. Sync your tasks across devices with your Nextcloud server.")
        .accessibilityAddTraits(.isButton)
    }
}

private struct IconBadge: View {
    let systemName: String
    let gradient: [Color]

    var body: some View {
        Image(systemName: systemName)
            .font(.title2)
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(
                LinearGradient(
                    colors: gradient,
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .accessibilityHidden(true)
    }
}

private struct FooterNote: View {
    var body: some View {
        Label {
            Text("Your data never leaves your device or your server. Zero tracking.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: "hand.raised.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
    }
}

#Preview {
    NavigationStack {
        AccountTypeChooserView()
    }
    .modelContainer(for: ServerAccount.self, inMemory: true)
}
