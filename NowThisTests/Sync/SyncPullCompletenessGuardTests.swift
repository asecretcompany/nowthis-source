import Foundation
import Testing

@testable import NowThis

/// Source guards for the foreground and background routes into the shared
/// bounded pull pipeline, plus the background-to-foreground refresh handoff.
/// Foreground sync returns the shared pull's change signal; background sync
/// leaves it pending until the scheduler consumes it.
/// The common pull resolves parents, reconciles complete manifests and commits
/// its checkpoint before publishing the resulting change.
@Suite("Sync / pull completeness")
struct SyncPullCompletenessGuardTests {

    /// The foreground and background owners of a complete calendar pull.
    static let fullPullFunctions = ["performBackgroundSyncRun", "syncCalendar"]

    /// Entry into the shared pull path and the landmark proving a real body.
    static let requiredStep = "pullCalendarCheckingPhotoAccess("
    static let bodyLandmark = "remoteCal"

    /// Foreground sync returns this signal directly. Background sync leaves it
    /// pending until the foreground scheduler bumps the committed query revision.
    static let inboundSignal = "inboundChanged"

    private func engineSource() throws -> String {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        return try String(contentsOf: root.appendingPathComponent("NowThis/Sync/SyncEngine.swift"),
                          encoding: .utf8)
    }

    /// The body of `func <name>`, by brace matching from its opening `{`.
    ///
    /// Deliberately naive. It counts braces without understanding string
    /// literals or comments, which is fine here because the result is only
    /// ever searched for a substring and every caller asserts a landmark — a
    /// mis-matched brace yields a body that fails its landmark rather than one
    /// that quietly passes.
    private func body(of name: String, in source: String) -> String? {
        guard let declaration = source.range(of: "func \(name)(") else { return nil }
        guard let open = source.range(of: "{", range: declaration.upperBound..<source.endIndex)
        else { return nil }

        var depth = 0
        var index = open.lowerBound
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[open.upperBound..<index])
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    @Test("Shared accounting resolves parents and reconciles absence before checkpoint commit")
    func sharedPullOwnsFinalization() throws {
        let source = try engineSource()
        let shared = try #require(body(of: "pullCalendar", in: source))
        #expect(shared.contains("writer.resolveParents("))
        #expect(shared.contains("writer.reconcileManifest("))
        #expect(shared.contains("commitPullCheckpoint("))
        #expect(shared.contains("reconcileCompleteManifest:"))
    }

    @Test("The photo-access wrapper forwards to the shared pull")
    func photoAccessWrapperForwardsToSharedPull() throws {
        let source = try engineSource()
        let wrapper = try #require(body(of: "pullCalendarCheckingPhotoAccess", in: source))
        #expect(wrapper.contains("return try await pullCalendar("),
                "The photo-access check must wrap and return the shared bounded pull result.")
        for argument in ["remoteCal: remoteCal", "resourceScope: scope",
                         "credentials: credentials", "container: container",
                         "months: months", "repairCategories: repairCategories"] {
            #expect(wrapper.contains(argument), "The wrapper stopped forwarding `\(argument)`. ")
        }
        let shared = try #require(body(of: "pullCalendar", in: source))
        #expect(shared.contains("writer.resolveParents("))
        #expect(shared.contains("writer.reconcileManifest("))
        #expect(shared.contains("commitPullCheckpoint("))
    }

    @Test("The public background budget wrapper delegates to the guarded pull body")
    func backgroundBudgetWrapperDelegatesToPullBody() throws {
        let source = try engineSource()
        let wrapper = try #require(body(of: "performBackgroundSync", in: source))
        #expect(wrapper.contains("try await performBackgroundSyncRun("),
                "The budget-owning entry must still invoke the complete background pull.")
        for argument in ["accountID: accountID", "serverBaseURL: serverBaseURL",
                         "credentials: credentials", "modelContainer: modelContainer",
                         "syncWindowMonths: syncWindowMonths", "reconcileNotifications: reconcileNotifications",
                         "runBudget: budget"] {
            #expect(wrapper.contains(argument), "The background wrapper stopped forwarding `\(argument)`.")
        }
    }

    @Test("Every full-pull path enters the shared bounded pull")
    func everyFullPullEntersSharedPipeline() throws {
        let source = try engineSource()

        var examined = 0
        for name in Self.fullPullFunctions {
            let found = try #require(body(of: name, in: source),
                                     "could not find the body of \(name) — the guard has gone stale")
            #expect(found.contains(Self.bodyLandmark), """
                \(name)'s extracted body has no \(Self.bodyLandmark) in it, so it is not the real \
                body and every assertion about it is meaningless.
                """)
            #expect(found.contains(Self.requiredStep), """
                \(name) never calls \(Self.requiredStep).

                A full-pull owner that bypasses the shared pipeline would skip its common \
                parent, manifest and checkpoint finalization.
                """)
            examined += 1
        }

        #expect(examined == Self.fullPullFunctions.count,
                "examined \(examined) pull paths; a guard that examines none reports success")
    }


    @Test("Every full-pull path reports the inbound changes it applied")
    func everyFullPullReportsInboundChanges() throws {
        let source = try engineSource()

        var examined = 0
        for name in Self.fullPullFunctions {
            let found = try #require(body(of: name, in: source),
                                     "could not find the body of \(name) — the guard has gone stale")
            #expect(found.contains(Self.bodyLandmark), """
                \(name)'s extracted body has no \(Self.bodyLandmark) in it, so it is not the real \
                body and every assertion about it is meaningless.
                """)
            #expect(found.contains(Self.inboundSignal), """
                \(name) never accumulates \(Self.inboundSignal).

                A pull that applies inbound tasks without reporting it leaves every live view \
                showing what it fetched before the pull ran. The rows are in the store; nothing \
                asked the view to look again.
                """)
            examined += 1
        }

        #expect(examined == Self.fullPullFunctions.count,
                "examined \(examined) pull paths; a guard that examines none reports success")
    }

    @Test("The scheduler turns a background pull's inbound changes into a refresh")
    func theSchedulerConsumesTheBackgroundSignal() throws {
        let root = try LocalizationCatalogFixture.repositoryRoot()
        let scheduler = try String(
            contentsOf: root.appendingPathComponent("NowThis/Sync/SyncScheduler.swift"),
            encoding: .utf8)

        #expect(scheduler.contains("dataRefreshToken = UUID()"), """
            SyncScheduler no longer bumps dataRefreshToken at all — this guard is anchored on it.
            """)

        let consume = "consumePendingInboundRefresh"
        let at = scheduler.range(of: consume)
        #expect(at != nil, """
            SyncScheduler never calls \(consume)().

            A background pull leaves its committed-change signal pending; without this consumer \
            the next foreground query revision would not be published.
            """)

        if let at {
            let after = scheduler[at.upperBound...].prefix(400)
            #expect(after.contains("dataRefreshToken"), """
                \(consume)() is called but no nearby dataRefreshToken bump publishes the \
                pending committed query revision.
                """)
        }
    }

    /// Proves the extractor can fail. Without this, a `body(of:)` that always
    /// returned a string containing everything would pass the test above.
    @Test("The body extractor returns only the named function's body")
    func theExtractorIsNotVacuous() throws {
        let source = """
            func alpha() {
                let x = { 1 }()
                callAlpha()
            }
            func beta() {
                callBeta()
            }
            """
        let alpha = try #require(body(of: "alpha", in: source))
        #expect(alpha.contains("callAlpha()"))
        #expect(!alpha.contains("callBeta()"), "the extractor ran past its own closing brace")
        #expect(body(of: "gamma", in: source) == nil, "a function that does not exist has no body")
    }
}
