import SwiftUI

/// The preference is captured at import time; changing it never rewrites existing photos.
struct TaskPhotoSettingsSection: View {
    @AppStorage("shareFullResolutionPhotos") private var shareFullResolutionPhotos = false

    var body: some View {
        Section {
            Toggle("Share full-resolution photos", isOn: $shareFullResolutionPhotos)
                .accessibilityIdentifier("taskPhotos.settings.shareFullResolution")
                .accessibilityHint("Applies only to photos you add from now on.")
        } header: {
            Text("Task Photos")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("Applies only to new photos. Optimized previews are always available offline. Full-resolution originals are limited to 25 MB each.", comment: "Changing the setting affects future imports only. Existing originals are not uploaded, removed, or reprocessed.")
                Text("Originals may include camera metadata, such as location, date, and device details. When shared, everyone with access to the list can download this information.", comment: "Privacy disclosure shown beside the full-resolution sharing toggle even while it is off. Originals may retain sensitive image metadata; previews strip location metadata.")
                Text("Originals are shared through Nextcloud Files after the list owner sets up sharing. Removing someone's list access may not revoke their access to originals until the owner's app syncs. This can take longer while the owner is offline.", comment: "Nextcloud Files permissions follow calendar membership only after the list owner's app syncs; revocation can lag while the owner is offline. Nextcloud Files is a product name.")
                Text("For Vault tasks, originals stay on this device.", comment: "Vault is NowThis's local-only account mode. Originals are never shared from Vault tasks.")
            }
            .accessibilityIdentifier("taskPhotos.settings.disclosure")
        }
    }
}
