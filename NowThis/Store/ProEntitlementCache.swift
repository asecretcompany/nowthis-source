import CryptoKit
import Foundation

/// Authenticates the exact snapshot bytes with an app-only Keychain key.
/// Legacy unsigned caches require a verified StoreKit refresh on first upgrade.
/// This protects integrity, not rollback of an older legitimately signed cache.
@MainActor
struct ProEntitlementCache {
    static let snapshotKey = "proEntitlementSnapshot.v1"
    private struct Envelope: Codable {
        var version: Int
        var payload: Data
        var tag: Data
    }

    let defaults: UserDefaults?
    private let keyProvider: @MainActor (_ createIfMissing: Bool) throws -> Data?

    init(defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID),
         keyProvider: @escaping @MainActor (Bool) throws -> Data? = {
             try KeychainManager.proEntitlementSigningKey(createIfMissing: $0)
         }) {
        self.defaults = defaults
        self.keyProvider = keyProvider
    }

    private static func authenticatedData(_ payload: Data) -> Data {
        // Domain and envelope version are authenticated along with the payload.
        Data("NowThis.ProEntitlementCache.v1\0".utf8) + payload
    }

    func load() -> ProAccessSnapshot? {
        guard let data = defaults?.data(forKey: Self.snapshotKey),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.version == 1, envelope.tag.count == 32,
              let key = try? keyProvider(false), key.count == 32,
              HMAC<SHA256>.isValidAuthenticationCode(envelope.tag,
                  authenticating: Self.authenticatedData(envelope.payload), using: SymmetricKey(data: key)),
              let snapshot = try? JSONDecoder().decode(ProAccessSnapshot.self, from: envelope.payload),
              snapshot.schemaVersion == 1 else { return nil }
        switch snapshot.access {
        case .lifetime: guard snapshot.validUntil == nil else { return nil }
        case .monthly, .annual: guard snapshot.validUntil != nil else { return nil }
        case .locked: break
        }
        return snapshot
    }

    /// Only the main app's verified evidence flow writes ownership snapshots.
    func save(_ snapshot: ProAccessSnapshot) {
        guard let defaults else { return }
        defer { defaults.removeObject(forKey: "proUnlocked") }
        do {
            guard let key = try keyProvider(true), key.count == 32 else {
                defaults.removeObject(forKey: Self.snapshotKey)
                return
            }
            let payload = try JSONEncoder().encode(snapshot)
            let tag = Data(HMAC<SHA256>.authenticationCode(for: Self.authenticatedData(payload), using: SymmetricKey(data: key)))
            let data = try JSONEncoder().encode(Envelope(version: 1, payload: payload, tag: tag))
            defaults.set(data, forKey: Self.snapshotKey)
        } catch {
            // A newer verified refund/expiry must not leave an old grant reusable
            // after a temporary Keychain or encoding failure has cleared.
            defaults.removeObject(forKey: Self.snapshotKey)
        }
    }
}
