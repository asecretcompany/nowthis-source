import Foundation

/// Exportable discovery context deliberately excludes server URLs and user data.
struct DAVDiscoveryFailure: Error, Sendable {
    enum Stage: String, Sendable { case principal, home, collections }
    enum Method: String, Sendable { case propfind = "PROPFIND" }
    enum Reason: String, CaseIterable, Sendable {
        case metadataMissing, untrustedAddress, incompleteListing, unsupportedResponse
        case methodNotAllowed, deadlineExceeded, ambiguousIdentity
    }
    let stage: Stage
    let method: Method
    let httpStatus: Int?
    let reason: Reason
}

extension DAVDiscoveryFailure: LocalizedError {
    var errorDescription: String? { SyncFailure.discoveryMessage(reason) }
}

extension DAVDiscoveryFailure.Stage {
    var displayName: String {
        switch self {
        case .principal: String(localized: "Account discovery")
        case .home: String(localized: "List home discovery")
        case .collections: String(localized: "List discovery")
        }
    }
}
