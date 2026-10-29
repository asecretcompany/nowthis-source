import Foundation

@MainActor
struct ProEntitlementCache {
    static let snapshotKey = "proEntitlementSnapshot.v1"
    let defaults: UserDefaults?
    init(defaults: UserDefaults? = UserDefaults(suiteName: AppConstants.appGroupID)) { self.defaults = defaults }
    func load() -> ProAccessSnapshot? {
        guard let data = defaults?.data(forKey: Self.snapshotKey),
              let snapshot = try? JSONDecoder().decode(ProAccessSnapshot.self, from: data),
              snapshot.schemaVersion == 1 else { return nil }
        switch snapshot.access {
        case .lifetime: guard snapshot.validUntil == nil else { return nil }
        case .monthly, .annual: guard snapshot.validUntil != nil else { return nil }
        case .locked: break
        }
        return snapshot
    }

    func save(_ snapshot: ProAccessSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults?.set(data, forKey: Self.snapshotKey)
        defaults?.removeObject(forKey: "proUnlocked")
    }
}
