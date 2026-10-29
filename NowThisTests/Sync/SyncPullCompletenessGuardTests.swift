import Foundation
import Testing

@testable import NowThis

/// Regression cover for **the two full-pull paths drifting apart.**
///
/// `SyncEngine` pulls in two places. `syncCalendar` runs when the app is in
/// front; `performBackgroundSyncRun`, reached through the budget-owning public
/// `performBackgroundSync` wrapper, runs from the BGTask with its own background
/// `ModelContext`. They apply the same remote tasks through the same appliers,
/// and then each finishes the pull its own way — which is where they differ,
/// silently, because nothing has ever compared them.
///
/// `performBackgroundSync` never called `resolveParentRelationships`. Inbound
/// subtasks carry their parent as `parentUID`, a string; the relationship the
/// UI reads is `parentTask`. Resolving one into the other is a separate pass,
/// and the background path skipped it. A subtask created on the server and
/// pulled in by a background refresh therefore arrived as a top-level row —
/// counted as one in the sidebar, shown as one in every list — and stayed that
/// way until the next foreground sync happened to run the pass for it.
///
/// ## Why this is a source guard
///
/// Scripted transport tests now exercise both paths. This source guard additionally
/// pins their shared orchestration entry point; neither path needs a live CalDAV
/// server, and the difference is not in what they compute but in a step one of
/// them omits. Nothing about the omission is observable from outside without
/// the network. So the assertion is on the source — the same tactic the
/// localization guards use, and brittle in the same deliberate way. Rename a
/// function here and this fails, which is the intended cost: the point is that
/// a *third* pull path, or a rename that drops the call, cannot land quietly.
///
/// The self-check below is what keeps it honest. A body extractor that
/// silently returns nothing would make every assertion here vacuous, so each
/// extracted body must contain a landmark that proves it is the real one.
@Suite("Sync / pull completeness")
struct SyncPullCompletenessGuardTests {

    /// The functions that perform a complete pull of a calendar. Both must
    /// finish it the same way.
    static let fullPullFunctions = ["performBackgroundSyncRun", "syncCalendar"]

    /// A step every full pull owes the store, and the landmark proving the
    /// extractor found a real body rather than an empty string.
    static let requiredStep = "pullCalendarCheckingPhotoAccess("
    static let bodyLandmark = "remoteCal"

    /// The signal every full pull owes the *UI*.
    ///
    /// A `@Query` bound to the main context does not re-emit when the sync engine's background
    /// context commits rows to the shared store, so a pull that applied anything has to say so:
    /// `SyncScheduler` turns that into `dataRefreshToken`, and `refreshOnInboundSync()` keys the
    /// task views off it. `syncCalendar` accumulated it and returned it; `performBackgroundSync`
    /// threw it away at the call — `_ = try applyRemoteTask(...)` — so a BGTask could commit new
    /// rows and no live view ever re-queried. The foreground sync that follows on `.active`
    /// cannot make up for it: the background pull already stored the new etags, so it finds
    /// nothing changed and reports `false`.
    static let inboundSignal = "inboundChanged"

    /// The shape of dropping it. Both appliers return "this was a real inbound change".
    static let discardedAppliers = ["_ = try applyRemoteTask", "_ = try processRemoteTask"]

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
        for argument in ["remoteCal: remoteCal", "listID: listID", "accountID: accountID",
                         "baseURL: baseURL", "credentials: credentials", "container: container",
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

    @Test("Every full-pull path resolves parent relationships")
    func everyFullPullResolvesParents() throws {
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

                A pull that does not resolve parentUID into parentTask leaves every inbound \
                subtask looking like a top-level task, in every list and in the sidebar count, \
                until some other pull happens to fix it.
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
            for discarded in Self.discardedAppliers {
                #expect(!found.contains(discarded), """
                    \(name) throws away the applier's result: `\(discarded)`.

                    That Bool is the inbound-change signal. Dropping it is how the background \
                    path came to commit rows no view ever re-queried.
                    """)
            }
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

            `performBackgroundSync` runs in the BGTask and cannot bump a `@Published` the views \
            are watching, so it leaves the fact that it applied something on the shared engine. \
            Nothing reads it here, so a background pull's rows stay invisible to any view that \
            was already on screen when the app went away.
            """)

        if let at {
            let after = scheduler[at.upperBound...].prefix(400)
            #expect(after.contains("dataRefreshToken"), """
                \(consume)() is called but nothing near it bumps dataRefreshToken, so consuming \
                the flag only clears it — the refresh it was standing for never happens.
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
