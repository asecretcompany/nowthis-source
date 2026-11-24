import Foundation
import Security
import Testing
@testable import NowThis

@Suite("Pro cache authentication", .serialized)
@MainActor
struct ProCacheAuthenticationTests {
    private let key = Data(repeating: 0x16, count: 32)
    private let grant = ProAccessSnapshot(access: .lifetime, earnedCollectionIDs: ["supporter-2026"])

    private func withCache(_ body: (UserDefaults, ProEntitlementCache) throws -> Void) throws {
        let suite = "NowThis.ProAuthentication.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, ProEntitlementCache(defaults: defaults, keyProvider: { _ in key }))
    }

    private func rewriteEnvelope(_ defaults: UserDefaults, _ change: (inout [String: Any]) throws -> Void) throws {
        let data = try #require(defaults.data(forKey: ProEntitlementCache.snapshotKey))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        try change(&object)
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ProEntitlementCache.snapshotKey)
    }

    @Test func modifyingPayloadRejectsTheEntireSnapshotBeforeUnlockOrArtwork() throws {
        try withCache { defaults, cache in
            cache.save(ProAccessSnapshot())
            try rewriteEnvelope(defaults) { object in
                object["payload"] = try JSONEncoder().encode(grant).base64EncodedString()
            }
            #expect(cache.load() == nil)
            let entitlement = ProEntitlement(client: ProStoreTestClient(), cache: cache,
                                             testerBuild: { false }, forcePaywall: { false })
            #expect(!entitlement.isUnlocked)
            #expect(entitlement.ownedCollectionIDs.isEmpty)
        }
    }

    @Test func modifyingTagRejectsAnOtherwiseLegitimateLifetime() throws {
        try withCache { defaults, cache in
            cache.save(grant)
            try rewriteEnvelope(defaults) { object in
                let encoded = try #require(object["tag"] as? String)
                var tag = try #require(Data(base64Encoded: encoded))
                tag[0] ^= 1
                object["tag"] = tag.base64EncodedString()
            }
            #expect(cache.load() == nil)
        }
    }

    @Test func forgedWellFormedEnvelopeCannotGrantLifetime() throws {
        try withCache { defaults, cache in
            let object: [String: Any] = ["version": 1,
                "payload": try JSONEncoder().encode(grant).base64EncodedString(),
                "tag": Data(repeating: 0, count: 32).base64EncodedString()]
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: ProEntitlementCache.snapshotKey)
            #expect(cache.load() == nil)
            #expect(!ProEntitlement.cachedUnlocked(cache: cache))
        }
    }

    @Test(arguments: ["version", "payload", "tag"])
    func malformedOrUnknownEnvelopeDoesNotLoad(field: String) throws {
        try withCache { defaults, cache in
            cache.save(grant)
            try rewriteEnvelope(defaults) { object in
                if field == "version" { object[field] = 99 }
                else { object[field] = "invalid base64" }
            }
            #expect(cache.load() == nil)
        }
    }

    @Test func unknownSnapshotSchemaIsRejectedEvenWithAValidSignature() throws {
        try withCache { _, cache in
            var snapshot = grant
            snapshot.schemaVersion = 99
            cache.save(snapshot)
            #expect(cache.load() == nil)
        }
    }

    @Test(arguments: [ProAccessKind.lifetime, .monthly, .annual])
    func inconsistentSignedDeadlinesAreRejected(kind: ProAccessKind) throws {
        try withCache { _, cache in
            cache.save(ProAccessSnapshot(access: kind, validUntil: kind == .lifetime ? Date() : nil))
            #expect(cache.load() == nil)
        }
    }

    @Test func wrongOrUnavailableKeyCannotUnlockAndReadNeverCreatesAKey() throws {
        try withCache { defaults, cache in
            cache.save(grant)
            var reads = 0
            let missing = ProEntitlementCache(defaults: defaults, keyProvider: { create in
                #expect(!create)
                reads += 1
                return nil
            })
            #expect(missing.load() == nil)
            #expect(reads == 1)
            let wrong = ProEntitlementCache(defaults: defaults, keyProvider: { _ in Data(repeating: 0x17, count: 32) })
            #expect(wrong.load() == nil)
            let locked = ProEntitlementCache(defaults: defaults, keyProvider: { _ in
                throw KeychainManager.KeychainError.osError(errSecInteractionNotAllowed)
            })
            #expect(locked.load() == nil)
            #expect(!ProEntitlement.cachedUnlocked(cache: locked))
            // A read failure alone must preserve a legitimate offline cache.
            #expect(cache.load() == grant)
        }
    }

    @Test(arguments: [0, 31, 33])
    func malformedSigningKeyCannotReadOrReplaceAnOlderGrant(length: Int) throws {
        try withCache { defaults, cache in
            cache.save(grant)
            let malformed = ProEntitlementCache(defaults: defaults, keyProvider: { _ in Data(repeating: 1, count: length) })
            #expect(malformed.load() == nil)
            malformed.save(ProAccessSnapshot())
            #expect(defaults.data(forKey: ProEntitlementCache.snapshotKey) == nil)
            #expect(cache.load() == nil)
        }
    }

    @Test func missingSigningKeyOnSaveInvalidatesOlderGrant() throws {
        try withCache { defaults, cache in
            cache.save(grant)
            let missing = ProEntitlementCache(defaults: defaults, keyProvider: { create in
                #expect(create)
                return nil
            })
            missing.save(ProAccessSnapshot())
            #expect(cache.load() == nil)
        }
    }

    @Test func encodingFailureInvalidatesOlderGrant() throws {
        try withCache { _, cache in
            cache.save(grant)
            cache.save(ProAccessSnapshot(access: .monthly, validUntil: Date(timeIntervalSince1970: .infinity)))
            #expect(cache.load() == nil)
        }
    }

    @Test func nilStorageNeverTouchesTheKeychain() {
        let cache = ProEntitlementCache(defaults: nil, keyProvider: { _ in
            Issue.record("A preview cache without storage must not touch Keychain")
            return nil
        })
        #expect(cache.load() == nil)
        cache.save(grant)
    }

    @Test func signingKeyUsesAnIsolatedNonSynchronizingDeviceOnlyItem() throws {
        let service = "NowThis.Tests.ProSigning.\(UUID().uuidString)"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service]
        defer { SecItemDelete(query as CFDictionary) }
        #expect(try KeychainManager.proEntitlementSigningKey(createIfMissing: false, service: service) == nil)
        let created = try #require(try KeychainManager.proEntitlementSigningKey(createIfMissing: true, service: service))
        // Assert properties only; never include signing material in failure output.
        #expect(created.count == 32)
        let reread = try KeychainManager.proEntitlementSigningKey(createIfMissing: false, service: service)
        let reused = try KeychainManager.proEntitlementSigningKey(createIfMissing: true, service: service)
        let rereadMatches = reread == created
        let reusedMatches = reused == created
        #expect(rereadMatches)
        #expect(reusedMatches)
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        attributesQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        #expect(SecItemCopyMatching(attributesQuery as CFDictionary, &result) == errSecSuccess)
        let attributes = try #require(result as? [String: Any])
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecAttrSynchronizable as String] as? Bool == false)
    }
}
