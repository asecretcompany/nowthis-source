import Foundation
import Observation

/// View-owned derived values. Managed models remain on their owner's main actor;
/// dependency changes invalidate synchronously before publishing a view update.
@MainActor
@Observable
final class ObservedProjectionCache<Key: Equatable & Sendable, Value> {
    private var revision: UInt64 = 0
    @ObservationIgnored private var cached: (key: Key, value: Value)?
    @ObservationIgnored private var invalidation: ProjectionInvalidation?

    func value(for key: Key, build: () -> Value) -> Value {
        _ = revision
        if let cached, cached.key == key, invalidation?.isInvalid == false {
            return cached.value
        }
        invalidation?.retire()
        let token = ProjectionInvalidation()
        invalidation = token
        let value = withObservationTracking {
            build()
        } onChange: { [weak self] in
            // Observation calls before the model write. Mark stale now so a
            // synchronous read after that write cannot return the old value.
            guard token.invalidate() else { return }
            Task { @MainActor [weak self] in
                // This notification was earned while the token was active.
                // A synchronous rebuild must not swallow it before delivery.
                self?.revision &+= 1
            }
        }
        cached = (key, value)
        return value
    }
}

/// Only this flag crosses the Sendable Observation callback; no model does.
private final class ProjectionInvalidation: @unchecked Sendable {
    private let lock = NSLock()
    private var invalid = false
    private var active = true
    var isInvalid: Bool { lock.withLock { invalid } }
    func retire() { lock.withLock { active = false } }
    func invalidate() -> Bool {
        lock.withLock {
            invalid = true
            return active
        }
    }
}
