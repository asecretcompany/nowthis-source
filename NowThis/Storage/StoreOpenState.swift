/// Describes whether the configured persistent store is available to the app.
enum StoreOpenState<Container> {
    case opened(Container)
    case recovery(message: String)

    var container: Container? {
        guard case .opened(let container) = self else { return nil }
        return container
    }

    var recoveryMessage: String? {
        guard case .recovery(let message) = self else { return nil }
        return message
    }

    var canPerformDataActions: Bool {
        if case .opened = self { return true }
        return false
    }
}

struct StoreOpenFailure: Error {
    let message: String
}
