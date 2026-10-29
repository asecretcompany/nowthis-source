import SwiftUI

struct StoreRecoveryView: View {
    let errorMessage: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your task data couldn't be opened", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 12) {
                Text("Unlock your device, free up storage space, or restart it before tapping Retry. Your saved data has been left in place.")
                Text("Store error: \(errorMessage)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } actions: {
            Button("Retry", action: onRetry)
                .buttonStyle(.borderedProminent)
                .accessibilityLabel(Text("Retry opening your saved task data"))
                .accessibilityHint(Text("This tries to open the same saved task store again."))
        }
        .padding()
    }
}
