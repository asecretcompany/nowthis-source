import SwiftUI

/// The add sheet owns its alert while presented; the root owns asynchronous failures
/// after dismissal. Standard alerts expose the whole message to VoiceOver.
struct WatchDeliveryFailureAlert: ViewModifier {
    @Environment(PhoneBridge.self) private var bridge
    var enabled = true

    func body(content: Content) -> some View {
        content.alert("Edit not confirmed", isPresented: Binding(
            get: { enabled && bridge.delivery.lastSendFailure != nil },
            set: { if !$0 { bridge.delivery.lastSendFailure = nil } }
        )) {
            Button("OK", role: .cancel) { bridge.delivery.lastSendFailure = nil }
        } message: {
            switch bridge.delivery.lastSendFailure {
            case .inactive:
                Text("Open NowThis on your iPhone, then try again.")
            case .tooLong:
                Text("This text is too long. Shorten it and try again.")
            case .queueFull:
                Text("Wait for pending edits or review saved drafts, then try again.")
            case .invalidDraft:
                Text("This task could not be added. Open Drafts to shorten the title or choose a list, then add it again.")
            case .rejected:
                Text("Your iPhone could not apply this edit. Open NowThis on your iPhone.")
            case .readOnly:
                Text(LocalizedStringResource(
                    "watch.edit.readOnly",
                    defaultValue: "This list is read-only. Ask the list owner for permission to edit it.",
                    comment: "Apple Watch alert when the iPhone refused a change to a task in a read-only list. Ask the list owner for permission."))
            case .readOnlyDraft:
                Text(LocalizedStringResource(
                    "watch.edit.readOnlyDraft",
                    defaultValue: "This list is read-only. Open Drafts and choose another list.",
                    comment: "Apple Watch alert when the iPhone refused an Add to a read-only list. Drafts is the Watch screen where the original task text stays available."))
            case .unconfirmed, .none:
                Text("Delivery could not be confirmed. Check your iPhone before trying again.")
            }
        }
    }
}
