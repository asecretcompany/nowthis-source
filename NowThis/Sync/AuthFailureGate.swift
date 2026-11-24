import Foundation
import CryptoKit

/// Tracks Nextcloud accounts whose credentials the server has rejected (HTTP 401),
/// so the sync scheduler stops re-sending the same failing Basic-Auth credentials.
///
/// **Why this exists:** Nextcloud's brute-force protection counts every failed
/// CalDAV Basic-Auth request as an incorrect login attempt. Sync runs on many
/// triggers (app foreground, task mutations, and `.task`/refresh on the Tasks,
/// Calendar, Kanban, and Matrix tabs), so without this gate a single stale or
/// revoked app password is re-sent over and over and locks the user out of their
/// own server.
///
/// The in-memory gate remembers the latest rejected password fingerprint for
/// each account, installation address and exact username. Editing any part
/// of the login can admit a new attempt. The password itself is never retained.
struct AuthFailureGate {
    struct Scope: Equatable {
        fileprivate let login: Login
        fileprivate let fingerprint: SHA256.Digest

        init(accountID: String, baseURL: String, username: String, password: String) {
            login = Login(accountID: accountID, server: Server(baseURL), username: Data(username.utf8))
            fingerprint = SHA256.hash(data: Data(password.utf8))
        }
    }

    fileprivate struct Login: Hashable {
        let accountID: String
        let server: Server
        // Basic Auth sends UTF-8 bytes. Swift String equality can treat distinct bytes as equal.
        let username: Data
    }

    fileprivate enum Server: Hashable {
        case https(host: String, port: Int, encodedPath: String)
        case unparsed(SHA256.Digest)

        init(_ raw: String) {
            guard let address = try? NextcloudServerAddress.parse(raw),
                  let host = NextcloudServerAddress.normalizedHost(address.baseURL),
                  let components = URLComponents(url: address.baseURL, resolvingAgainstBaseURL: false) else {
                self = .unparsed(SHA256.hash(data: Data(raw.utf8)))
                return
            }
            self = .https(host: host, port: components.port ?? 443, encodedPath: components.percentEncodedPath)
        }
    }

    private var rejectedFingerprints: [Login: SHA256.Digest] = [:]

    mutating func recordFailure(_ scope: Scope) {
        rejectedFingerprints[scope.login] = scope.fingerprint
    }

    func shouldSkip(_ scope: Scope) -> Bool {
        rejectedFingerprints[scope.login] == scope.fingerprint
    }
}
