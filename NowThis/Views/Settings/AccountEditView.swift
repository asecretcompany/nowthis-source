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
    @State private var formAccountScope: AccountCredentialScope?
    @State private var reauthAccountScope: AccountCredentialScope?
    @State private var loginSaveTask: Task<Void, Never>?
    @StateObject private var loginCoordinator = PerformanceLaunchFixture.makeLoginCoordinator()

    enum TestResult {
        case success
        case reauthenticated
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
                        credentialsUpdated: credentialsUpdated,
                        startAction: startReauthentication
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
        .disabled(isSaving || loginSaveTask != nil)
        .onAppear { populateFields() }
        .onChange(of: displayName) { _, _ in checkChanges() }
        .onChange(of: serverURL) { _, _ in checkChanges() }
        .onChange(of: username) { _, _ in checkChanges() }
        .onChange(of: password) { _, _ in checkChanges() }
        .onChange(of: loginCoordinator.state) { _, newState in
            handleReauthState(newState)
        }
        .onDisappear {
            loginCoordinator.cancel()
            reauthAccountScope = nil
            loginSaveTask?.cancel()
            loginSaveTask = nil
        }
        }
    }

    // MARK: - Data

    private func populateFields() {
        guard formAccountScope == nil else { return }
        formAccountScope = AccountCredentialScope(account)
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
        guard let formAccountScope else { return }
        isTesting = true
        defer { isTesting = false }
        testResult = nil
        testResult = await Self.performConnectionTest(account: formAccountScope,
            serverURL: serverURL, username: username, password: password, in: modelContext)
    }

    @MainActor
    static func performConnectionTest(
        account: AccountCredentialScope, serverURL: String, username: String, password: String,
        in context: ModelContext, keychainManager: KeychainManager = KeychainManager(),
        configuration: URLSessionConfiguration? = nil
    ) async -> TestResult? {
        let testPassword: String
        if password.isEmpty {
            let manager = AccountManager(modelContext: context, keychainManager: keychainManager)
            let credentials: (username: String, password: String)?
            do {
                credentials = try await manager.getCredentials(for: account.id, expected: account)
            } catch is AccountCredentialDeferral {
                return nil
            } catch {
                credentials = nil
            }
            guard let credentials else {
                return .failure("No stored credentials found. Enter your password.")
            }
            testPassword = credentials.password
        } else {
            testPassword = password
        }

        var testURL = serverURL.isEmpty ? account.serverBaseURL : serverURL
        if testURL == account.serverBaseURL,
           let address = try? NextcloudDiscoverySeed.address(accountID: account.id, serverURL: account.serverBaseURL, in: context),
           let seed = address.discoverySeed {
            testURL = seed.absoluteString
        }
        let testUser = username.isEmpty ? account.username : username

        do {
            let success = try await ServerURLValidator.testConnection(
                baseURL: testURL,
                username: testUser,
                password: testPassword,
                configuration: configuration
            )
            return success
                ? .success
                : .failure("Could not connect. Check your URL and credentials.")
        } catch {
            return .failure(SyncFailure.connectionGuidance(for: error) ?? error.localizedDescription)
        }
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
        guard !isSaving else { return }
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let accountID = account.id
        let manager = AccountManager(modelContext: modelContext)
        saveError = await Self.performAccountRemoval(
            accountID: accountID, remove: manager.removeAccount,
            dismiss: { dismiss() })
    }

    /// The async deletion boundary shared by the sheet and its failure regression.
    @MainActor
    static func performAccountRemoval(
        accountID: String,
        remove: (String) async throws -> Void,
        dismiss: () -> Void
    ) async -> String? {
        do {
            try await remove(accountID)
            dismiss()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Re-authentication (Login Flow)

    private var credentialsUpdated: Bool {
        if case .reauthenticated = testResult { return true }
        return false
    }

    private func startReauthentication() {
        let scope = AccountCredentialScope(account)
        reauthAccountScope = scope
        loginCoordinator.startLoginFlow(serverURL: scope.serverBaseURL)
    }

    private func handleReauthState(_ state: LoginFlowCoordinator.State) {
        switch state {
        case .initiating:
            saveError = nil
            if credentialsUpdated { testResult = nil }
        case .success(let server, let loginName, let appPassword):
            guard loginSaveTask == nil, let initiatingScope = reauthAccountScope else { return }
            reauthAccountScope = nil
            loginSaveTask = Task {
                defer { if !Task.isCancelled { loginSaveTask = nil } }
                await AccountLoginSave.perform(save: {
                    let manager = PerformanceLaunchFixture.loginAccountManager(in: modelContext)
                    try await manager.reauthenticateNextcloudAccount(
                        account: initiatingScope,
                        returnedServer: server,
                        loginName: loginName,
                        appPassword: appPassword
                    )
                }, onSuccess: {
                    saveError = nil
                    testResult = .reauthenticated
                }, onFailure: { saveError = $0 })
            }
            loginCoordinator.cancel()
        case .error(let message):
            reauthAccountScope = nil
            saveError = message
        case .idle:
            reauthAccountScope = nil
        case .waitingForBrowser:
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
    let credentialsUpdated: Bool
    let startAction: () -> Void

    var body: some View {
        Section {
            Button(action: startAction) {
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

            if credentialsUpdated {
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
                if let address = try? NextcloudServerAddress.parse(serverURL), address.discoverySeed != nil {
                    Text(String(format: String(localized: "account.server.normalization", defaultValue: "Server address: %@", comment: "Shows the installation server address extracted from a pasted CalDAV endpoint. The placeholder is the server URL."), address.baseURL.absoluteString))
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .accessibilityLabel(isTesting
                                ? String(localized: "account.a11y.testingConnection",
                                         defaultValue: "Testing connection",
                                         comment: "VoiceOver label while the server connectivity check is running.")
                                : String(localized: "account.a11y.testConnection",
                                         defaultValue: "Test connection",
                                         comment: "VoiceOver label for the button that checks server connectivity. Spoken, not shown — sentence case, unlike the visible 'Test Connection' button."))
            .accessibilityHint("Double tap to verify server connectivity")

            if let result = testResult {
                switch result {
                case .success:
                    Label("List discovery succeeded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.subheadline)
                case .reauthenticated:
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
            .accessibilityLabel(isSaving
                                ? String(localized: "account.a11y.savingChanges",
                                         defaultValue: "Saving changes",
                                         comment: "VoiceOver label while the account edits are being written.")
                                : String(localized: "account.a11y.saveChanges",
                                         defaultValue: "Save changes",
                                         comment: "VoiceOver label for the button that saves account edits. Spoken, not shown — sentence case, unlike the visible 'Save Changes' button."))
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
                Text("Lists")
                Spacer()
                Text(account.taskLists.count, format: .number)
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
            .accessibilityLabel(String(localized: "account.a11y.delete",
                                       defaultValue: "Delete account",
                                       comment: "VoiceOver label for the button that removes this account from the device. Spoken, not shown — sentence case, unlike the visible 'Delete Account' button."))
            .accessibilityHint("Double tap to remove this account from this device")
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
                Text("This removes the account and its lists from this device. Tasks that have never reached the server are moved to a Recovered Tasks list so you keep them; everything already synced stays on your server. This can't be undone here.")
            }
        } header: {
            Text("Danger Zone")
        }
    }
}
