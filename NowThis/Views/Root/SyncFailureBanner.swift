import SwiftUI

/// A dismissible banner that surfaces the most recent sync failure in plain
/// language. It stays until the failure clears (a later sync succeeds) or the
/// user dismisses it. Actionable failures (wrong credentials, bad server
/// address) are tappable and route the user to Settings.
struct SyncFailureBanner: View {
    let failure: SyncFailure
    /// Invoked when the banner is tapped, for `isUserActionable` failures only.
    var onTap: (() -> Void)?
    let onDismiss: () -> Void

    /// Decides whether the banner should be on screen given the current sync
    /// failure and the failure the user last dismissed. A new, *different*
    /// failure reappears even after a prior dismissal.
    static func isVisible(failure: SyncFailure?, dismissed: SyncFailure?) -> Bool {
        guard let failure else { return false }
        return failure != dismissed
    }

    var body: some View {
        let isActionable = failure.isUserActionable && onTap != nil

        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(failure.message)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if isActionable {
                    Text("Tap to fix")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
            }
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .onTapGesture {
            if isActionable { onTap?() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(failure.message)
        .accessibilityHint(isActionable ? "Double-tap to open Settings and fix your account." : "")
        .accessibilityAddTraits(isActionable ? .isButton : [])
    }

    private var iconName: String {
        switch failure.category {
        case .authentication: return "person.crop.circle.badge.exclamationmark"
        case .accessDenied: return "lock.fill"
        case .connection: return "wifi.exclamationmark"
        case .server, .busy: return "exclamationmark.icloud.fill"
        case .configuration: return "gearshape.fill"
        case .unknown: return "exclamationmark.triangle.fill"
        }
    }

    /// Red for things the user must fix; muted orange for transient/server-side
    /// problems that resolve on their own.
    private var tint: Color {
        switch failure.category {
        case .authentication, .accessDenied, .configuration:
            return .red
        case .connection, .server, .busy, .unknown:
            return .orange
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        SyncFailureBanner(
            failure: SyncFailure(category: .authentication, message: SyncFailure.authMessage),
            onTap: {},
            onDismiss: {}
        )
        SyncFailureBanner(
            failure: SyncFailure(category: .connection, message: SyncFailure.connectionMessage),
            onDismiss: {}
        )
    }
}
