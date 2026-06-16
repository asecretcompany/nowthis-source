import SwiftUI
import SwiftData

/// Nextcloud server connection view with Login Flow v2 as the primary authentication method.
///
/// The user enters their server URL, then either:
/// 1. **Login Flow v2** (recommended) — taps "Sign in with Nextcloud" to authenticate
///    in their browser. The server generates a named app password automatically.
/// 2. **Manual entry** (fallback) — expands the "Advanced" section to paste an
///    app password created in Nextcloud's Security settings.
struct AccountSetupView: View {

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var serverURL = ""
    @State private var connectionError: String?
    @State private var accountCreated = false
    @StateObject private var loginCoordinator = LoginFlowCoordinator()

    // Manual entry fallback
    @State private var showManualEntry = false
    @State private var username = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isConnecting = false

    var body: some View {
        Form {
            ServerURLSection(serverURL: $serverURL)

            if AccountSetupHelper.shouldShowLoginSections(serverURL: serverURL) {
                LoginFlowSection(
                    coordinator: loginCoordinator,
                    canStart: canStartLoginFlow,
                    startAction: startLoginFlow
                )

                ManualEntrySection(
                    showManualEntry: $showManualEntry,
                    username: $username,
                    password: $password,
                    showPassword: $showPassword,
                    isConnecting: isConnecting,
                    canConnect: canConnectManually,
                    connectAction: { Task { await connectManually() } }
                )
            } else if !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section {
                    Label {
                        Text("Enter a valid HTTPS server address to continue.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "arrow.up.circle")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let error = connectionError {
                Section {
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
        .navigationTitle("Add Nextcloud")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isConnecting)
        .onChange(of: loginCoordinator.state) { _, newState in
            handleLoginFlowState(newState)
        }
    }

    // MARK: - Login Flow

    private var canStartLoginFlow: Bool {
        let validation = ServerURLValidator.validate(serverURL)
        return validation.isValid && loginCoordinator.state != .initiating
            && loginCoordinator.state != .waitingForBrowser
    }

    private func startLoginFlow() {
        connectionError = nil
        let validation = ServerURLValidator.validate(serverURL)
        guard validation.isValid else {
            connectionError = validation.errorMessage
            return
        }
        loginCoordinator.startLoginFlow(serverURL: validation.normalizedURL)
    }

    private func handleLoginFlowState(_ state: LoginFlowCoordinator.State) {
        switch state {
        case .success(let server, let loginName, let appPassword):
            Task {
                do {
                    let manager = AccountManager(modelContext: modelContext)
                    try await manager.addNextcloudAccountViaLoginFlow(
                        serverURL: server,
                        loginName: loginName,
                        appPassword: appPassword
                    )
                    accountCreated = true
                    dismiss()
                } catch {
                    connectionError = error.localizedDescription
                }
            }
        case .error(let message):
            connectionError = message
        default:
            break
        }
    }

    // MARK: - Manual Entry

    private var canConnectManually: Bool {
        let validation = ServerURLValidator.validate(serverURL)
        let hasCredentials = !username.trimmingCharacters(in: .whitespaces).isEmpty
            && !password.isEmpty
        return validation.isValid && hasCredentials && !isConnecting
    }

    private func connectManually() async {
        isConnecting = true
        connectionError = nil

        let validation = ServerURLValidator.validate(serverURL)
        guard validation.isValid else {
            connectionError = validation.errorMessage
            isConnecting = false
            return
        }

        let normalizedURL = validation.normalizedURL
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)

        do {
            let success = try await ServerURLValidator.testConnection(
                baseURL: normalizedURL,
                username: trimmedUsername,
                password: password
            )

            if success {
                let manager = AccountManager(modelContext: modelContext)
                try await manager.addNextcloudAccount(
                    displayName: trimmedUsername,
                    serverURL: normalizedURL,
                    username: trimmedUsername,
                    password: password
                )
                password = "" // Clear from memory (SEC-01)
                accountCreated = true
                dismiss()
            } else {
                connectionError = String(
                    localized: "Could not connect to server. Please check your URL and credentials."
                )
            }
        } catch {
            connectionError = String(
                localized: "Connection failed: \(error.localizedDescription)"
            )
        }

        isConnecting = false
    }
}

// MARK: - Server URL Section

private struct ServerURLSection: View {
    @Binding var serverURL: String

    var body: some View {
        Section {
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
        } header: {
            Text("Server URL")
        } footer: {
            Text("Enter your Nextcloud server address. HTTPS is required and added automatically if omitted.")
        }
    }
}

// MARK: - Login Flow Section

private struct LoginFlowSection: View {
    @ObservedObject var coordinator: LoginFlowCoordinator
    let canStart: Bool
    let startAction: () -> Void

    var body: some View {
        Section {
            Button(action: startAction) {
                HStack {
                    Spacer()
                    switch coordinator.state {
                    case .initiating:
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 8)
                        Text("Connecting…")
                            .fontWeight(.semibold)
                    case .waitingForBrowser:
                        ProgressView()
                            .tint(.white)
                            .padding(.trailing, 8)
                        Text("Waiting for browser…")
                            .fontWeight(.semibold)
                    default:
                        Image(systemName: "person.badge.key.fill")
                        Text("Sign in with Nextcloud")
                            .fontWeight(.semibold)
                    }
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 4)
            }
            .listRowBackground(
                RoundedRectangle(cornerRadius: 10)
                    .fill(canStart ? .blue : .gray.opacity(0.4))
            )
            .disabled(!canStart)
            .accessibilityLabel(
                coordinator.state == .waitingForBrowser
                    ? "Waiting for browser login"
                    : "Sign in with Nextcloud"
            )
            .accessibilityHint("Opens your Nextcloud login page in a browser window")
        } header: {
            Text("Sign In")
        } footer: {
            Text("Opens your Nextcloud server in a browser. Log in and grant access — your credentials stay in the browser, never in this app.")
        }
    }
}

// MARK: - Manual Entry Fallback

private struct ManualEntrySection: View {
    @Binding var showManualEntry: Bool
    @Binding var username: String
    @Binding var password: String
    @Binding var showPassword: Bool
    let isConnecting: Bool
    let canConnect: Bool
    let connectAction: () -> Void

    var body: some View {
        Section {
            DisclosureGroup("Enter app password manually", isExpanded: $showManualEntry) {
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
                        TextField("App Password", text: $password)
                            .textContentType(.password)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    } else {
                        SecureField("App Password", text: $password)
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

                Button(action: connectAction) {
                    HStack {
                        Spacer()
                        if isConnecting {
                            ProgressView()
                                .tint(.white)
                                .padding(.trailing, 8)
                            Text("Connecting…")
                                .fontWeight(.semibold)
                        } else {
                            Image(systemName: "arrow.right.circle.fill")
                            Text("Connect")
                                .fontWeight(.semibold)
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .padding(.vertical, 4)
                }
                .listRowBackground(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(canConnect ? .blue : .gray.opacity(0.4))
                )
                .disabled(!canConnect)
            }
        } footer: {
            Text("For servers that don't support Login Flow, create an app password in Nextcloud → Settings → Security.")
        }
    }
}

#Preview {
    NavigationStack {
        AccountSetupView()
    }
    .modelContainer(for: ServerAccount.self, inMemory: true)
}
