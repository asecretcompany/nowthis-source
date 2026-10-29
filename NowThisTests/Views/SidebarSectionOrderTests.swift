import Testing
@testable import NowThis

/// Characterisation tests for the sidebar's order codec.
///
/// `AppTab` is modelled on this type's *shape*, not its implementation. Two
/// behaviours below are latent bugs, asserted here as they actually are so
/// that `AppTabTests` can assert the opposite and the difference is visible.
@Suite("SidebarSection / order codec")
struct SidebarSectionOrderTests {

    @Test("Round-trips a reordered array")
    func roundTripsReorderedArray() {
        let reordered: [SidebarSection] = [.lists, .tags, .journals, .filters]
        let json = SidebarSection.encodeOrder(reordered)
        #expect(SidebarSection.loadOrder(from: json) == reordered)
    }

    @Test("Falls back to default on empty input")
    func fallsBackOnEmptyInput() {
        #expect(SidebarSection.loadOrder(from: "") == SidebarSection.defaultOrder)
    }

    @Test("Falls back to default on malformed JSON")
    func fallsBackOnGarbage() {
        #expect(SidebarSection.loadOrder(from: "not json") == SidebarSection.defaultOrder)
    }

    /// Not a bug. An empty array decodes successfully and is returned verbatim,
    /// because an empty stored list is something the user chose rather than
    /// something that went wrong; the invariant that the sidebar always shows
    /// *something* lives at the call site (`SidebarView.swift:167`) rather than
    /// here. `AppTab` used to substitute its default on this input and stopped —
    /// see `AppTabTests.emptyStoredListIsHonoured` for why.
    ///
    /// The two loaders agree on **this** input only. They still differ on the
    /// next one down: one unknown raw value discards the whole stored order
    /// here, where `AppTab` drops the single bad entry.
    @Test("An empty stored array survives the loader untouched")
    func emptyArraySurvivesLoader() {
        #expect(SidebarSection.loadOrder(from: "[]") == [])
    }

    /// LATENT BUG, asserted as-is. An unknown raw value makes `JSONDecoder`
    /// throw, the `try?` swallows it, and the user's entire custom order is
    /// silently replaced by the default — one stale token discards all of it.
    @Test("One unknown raw value discards the whole stored order")
    func unknownRawValueDiscardsEverything() {
        let json = #"["lists","tags","retired"]"#
        #expect(SidebarSection.loadOrder(from: json) == SidebarSection.defaultOrder)
    }

    /// LATENT BUG, asserted as-is. A case added in a later build is absent from
    /// an existing user's stored array, so it never reaches the `ForEach` and
    /// is invisible with no way to re-enable it.
    @Test("A case missing from the stored order is never appended")
    func missingCaseIsNotAppended() {
        let json = SidebarSection.encodeOrder([.lists, .tags])
        #expect(SidebarSection.loadOrder(from: json) == [.lists, .tags])
        #expect(SidebarSection.loadOrder(from: json).count < SidebarSection.allCases.count)
    }
}
