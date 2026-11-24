import Testing

@testable import NowThis

@Suite("Portrait widget row packing")
struct WidgetDisplayPolicyTests {
    @Test("Rows fit the available height and both candidate limits", arguments: [
        (300.0, 20, 5),
        (600.0, 20, 11),
        (2_000.0, 30, 20),
        (300.0, 2, 2),
        (79.0, 20, 0),
        (300.0, 0, 0),
        (300.0, -1, 0),
        (123.0, 20, 0),
        (124.0, 20, 1),
        (Double.greatestFiniteMagnitude, Int.max, 20)
    ])
    func packsWholeRows(height: Double, candidates: Int, expected: Int) {
        #expect(WidgetDisplayPolicy.portraitVisibleCount(
            availableHeight: height, headerHeight: 80, rowHeight: 36, spacing: 8,
            candidateCount: candidates
        ) == expected)
    }

    @Test("Invalid layout dimensions do not allocate rows", arguments: [
        (Double.nan, 80.0, 36.0, 8.0),
        (Double.infinity, 80.0, 36.0, 8.0),
        (300.0, Double.nan, 36.0, 8.0),
        (300.0, 80.0, Double.infinity, 8.0),
        (300.0, 80.0, 36.0, Double.nan),
        (300.0, 80.0, 0.0, 0.0),
        (300.0, 80.0, -1.0, 0.0),
        (300.0, 80.0, Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude)
    ])
    func invalidGeometry(height: Double, header: Double, row: Double, spacing: Double) {
        #expect(WidgetDisplayPolicy.portraitVisibleCount(
            availableHeight: height, headerHeight: header, rowHeight: row, spacing: spacing,
            candidateCount: 20
        ) == 0)
    }
}
