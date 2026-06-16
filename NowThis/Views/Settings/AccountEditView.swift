import SwiftUI
import SwiftData

/// Edit view for an existing Nextcloud account.
///
/// Allows the user to update server URL, credentials, display name,
/// and provides options to test the connection, re-sync, or delete the account.
struct AccountEditView: View {

    let account: ServerAccount
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var displayName: String = ""
    @State private var serverURL: String = ""
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var showPassword = false
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var saveError: String?
    @State private var testResult: TestResult?
    @State private var showDeleteConfirmation = false
    @State private var hasChanges = false
    @StateObject private var loginCoordinator = LoginFlowCoordinator()

    fileprivate enum TestResult {
        case success
        case failure(String)
    }

    var body: some View {
        if account.modelContext == nil {
            Color.clear
                .onAppear { dismiss() }
        } else {
            Form {
            DisplayNameSection(displayName: $displayName)

            ServerSection(
                serverURL: $serverURL,
                isVault: account.mode == .vault
            )

            if account.mode == .nextcloud {
                if account.resolvedAuthMethod == .loginFlow {
                    ReauthenticateSection(
                        coordinator: loginCoordinator,
                        serverURL: account.serverBaseURL
                    )
                } else {
                    EditCredentialsSection(
                        username: $username,
                        password: $password,
                        showPassword: $showPassword
                    )
                }

                TestConnectionSection(
                    isTesting: isTesting,
                    testResult: testResult,
                    testAction: { Task { await testConnection() } }
                )
            }

            SaveSection(
                isSaving: isSaving,
                hasChanges: hasChanges,
                saveError: saveError,
                saveAction: { Task { await save() } }
            )

            SyncInfoSection(account: account)

            DangerZoneSection(
                showConfirmation: $showDeleteConfirmation,
                deleteAction: { Task { await deleteAccount() } }
            )
        }
        .navigationTitle("Edit Account")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isSaving)
        .onAppear { populateFields() }
        .onChange(of: displayName) { _, _ in checkChanges() }
        .onChange(of: serverURL) { _, _ in checkChanges() }
        .onChange(of: username) { _, _ in checkChanges() }
        .onChange(of: password) { _, _ in checkChanges() }
        .onChange(of: loginCoordinator.state) { _, newState in
            handleReauthState(newState)
        }
        }
    }

    // MARK: - Data

    private func populateFields() {
        displayName = account.displayName
        serverURL = account.serverBaseURL
        username = account.username
        password = "" // Never pre-fill passwords from Keychain
    }

    private func checkChanges() {
        hasChanges = displayName != account.displayName
            || serverURL != account.serverBaseURL
            || username != account.username
            || !password.isEmpty
    }

    // MARK: - Actions

    private func testConnection() async {
        isTesting = true
        testResult = nil

        let testPassword: String
        if password.isEmpty {
            // Use existing Keychain password
            let manager = AccountManager(modelContext: modelContext)
            if let creds = try? await manager.getCredentials(for: account.id) {
                testPassword = creds.password
            } else {
                testResult = .failure("No stored credentials found. Enter your password.")
                isTesting = false
                return
            }
        } else {
            testPassword = password
        }

        let testURL = serverURL.isEmpty ? account.serverBaseURL : serverURL
        let testUser = username.isEmpty ? account.username : username

        do {
            let success = try await ServerURLValidator.testConnection(
                baseURL: testURL,
                username: testUser,
                password: testPassword
            )
            testResult = success
                ? .success
                : .failure("Could not connect. Check your URL and credentials.")
        } catch {
            testResult = .failure(error.localizedDescription)
        }

        isTesting = false
    }

    private func save() async {
        isSaving = true
        saveError = nil

        let manager = AccountManager(modelContext: modelContext)

        do {
            try await manager.updateNextcloudAccount(
                accountID: account.id,
                displayName: displayName.isEmpty ? nil : displayName,
                serverURL: serverURL.isEmpty ? nil : serverURL,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password
            )
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }

        isSaving = false
    }

    private func deleteAccount() async {
        let manager = AccountManager(modelContext: modelContext)
        try? await manager.removeAccount(accountID: account.id)
        dismiss()
    }

    // MARK: - Re-authentication (Login Flow)

    private func handleReauthState(_ state: LoginFlowCoordinator.State) {
        switch state {
        case .success(_, let loginName, let appPassword):
            Task {
                do {
                    let manager = AccountManager(modelContext: modelContext)
                    try await manager.updateNextcloudAccount(
                        accountID: account.id,
                        username: loginName,
                        password: appPassword
                    )
                    saveError = nil
                    testResult = .success
                } catch {
                    saveError = error.localizedDescription
                }
            }
        case .error(let message):
            saveError = message
        default:
            break
        }
    }
}

// MARK: - Display Name

private struct DisplayNameSection: View {
    @Binding var displayName: String

    var body: some View {
        Section {
            HStack {
                Image(systemName: "person.text.rectangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Display Name", text: $displayName)
                    .accessibilityLabel("Account display name")
            }
        } header: {
            Text("Display Name")
        } footer: {
            Text("A friendly name shown in the sidebar and settings.")
        }
    }
}

// MARK: - Re-authenticate (Login Flow)

private struct ReauthenticateSection: View {
    @ObservedObject var coordinator: LoginFlowCoordinator
    let serverURL: String

    var body: some View {
        Section {
            Button {
                coordinator.startLoginFlow(serverURL: serverURL)
            } label: {
                HStack {
                    switch coordinator.state {
                    case .initiating:
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Connecting…")
                    case .waitingForBrowser:
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Waiting for browser…")
                    default:
                        Image(systemName: "arrow.triangle.2.circlepath")
                        Text("Re-authenticate")
                    }
                }
            }
            .disabled(
                coordinator.state == .initiating
                    || coordinator.state == .waitingForBrowser
            )
            .accessibilityLabel("Re-authenticate with Nextcloud")
            .accessibilityHint("Opens your Nextcloud login page to generate a new app password")

            if case .success = coordinator.state {
                Label("Credentials updated", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.subheadline)
            }
        } header: {
            Text("Authentication")
        } footer: {
            Text("This account uses Nextcloud Login Flow. Tap to re-authenticate if your access was revoked.")
        }
    }
}

// MARK: - Server URL

private struct ServerSection: View {
    @Binding var serverURL: String
    let isVault: Bool

    var body: some View {
        Section {
            if isVault {
                Label {
                    Text("Local device only — no server")
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(.purple)
                }
            } else {
                HStack {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("cloud.example.com", text: $serverURL)
                        .textContentType(.URL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .accessibilityLabel("Server URL")
                }
            }
        } header: {
            Text("Server")
        }
    }
}

// MARK: - Credentials

private struct EditCredentialsSection: View {
    @Binding var username: String
    @Binding var password: String
    @Binding var showPassword: Bool

    var body: some View {
        Section {
            HStack {
                Image(systemName: "person")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            HStack {
                Image(systemName: "key")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if showPassword {
                    TextField("New App Password", text: $password)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } else {
                    SecureField("New App Password", text: $password)
                        .textContentType(.password)
                }
                Button {
                    showPassword.toggle()
                } label: {
                    Image(systemName: showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
            }
        } header: {
            Text("Credentials")
        } footer: {
            Text("Leave the password blank to keep your current password unchanged.")
        }
    }
}

// MARK: - Test Connection

private struct TestConnectionSection: View {
    let isTesting: Bool
    let testResult: AccountEditView.TestResult?
    let testAction: () -> Void

    var body: some View {
        Section {
            Button(action: testAction) {
                HStack {
                    if isTesting {
                        ProgressView()
                            .padding(.trailing, 4)
                        Text("Testing…")
                    } else {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Test Connection")
                    }
                }
            }
            .disabled(isTesting)
            .accessibilityLabel(isTesting ? "Testing connection" : "Test connection")
            .accessibilityHint("Double tap to verify server connectivity")

            if let result = testResult {
                switch result {
                case .success:
                    Label("Connection successful", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                case .failure(let message):
                    Label {
                        Text(message)
                            .font(.caption)
                    } icon: {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }
}

// MARK: - Save

private struct SaveSection: View {
    let isSaving: Bool
    let hasChanges: Bool
    let saveError: String?
    let saveAction: () -> Void

    var body: some View {
        Section {
            Button(action: saveAction) {
                HStack {
                    Spacer()
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 8)
                        Text("Saving…")
                            .fontWeight(.semibold)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Save Changes")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 4)
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10)
                    .fill(hasChanges ? .blue : .gray.opacity(0.4))
            )
            .disabled(!hasChanges || isSaving)
            .accessibilityLabel(isSaving ? "Saving changes" : "Save changes")
            .accessibilityHint(hasChanges ? "Double tap to save your account changes" : "Make changes to enable saving")

            if let error = saveError {
                Label {
                    Text(error)
                        .font(.caption)
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill")
                }
                .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Sync Info

private struct SyncInfoSection: View {
    let account: ServerAccount

    var body: some View {
        Section("Sync Status") {
            HStack {
                Text("Last Sync")
                Spacer()
                if let lastSync = account.lastSyncDate {
                    Text(lastSync, format: .relative(presentation: .named))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never")
                        .foregroundStyle(.tertiary)
                }
            }

            HStack {
                Text("Task Lists")
                Spacer()
                Text("\(account.taskLists.count)")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Danger Zone

private struct DangerZoneSection: View {
    @Binding var showConfirmation: Bool
    let deleteAction: () -> Void

    var body: some View {
        Section {
            Button(role: .destructive) {
                showConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Image(systemName: "trash")
                    Text("Delete Account")
                        .fontWeight(.semibold)
                    Spacer()
                }
            }
            .accessibilityLabel("Delete account")
            .accessibilityHint("Double tap to permanently delete this account and all its data")
            .confirmationDialog(
                "Delete this account?",
                isPresented: $showConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete Account & All Data", role: .destructive) {
                    deleteAction()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will permanently delete the account, all task lists, and all tasks. This action cannot be undone.")
            }
        } header: {
            Text("Danger Zone")
        }
    }
}
