import Foundation

enum WidgetDisplayPolicy {
    static let portraitCandidateLimit = 20

    static func portraitVisibleCount(
        availableHeight: Double,
        headerHeight: Double,
        rowHeight: Double,
        spacing: Double,
        candidateCount: Int
    ) -> Int {
        guard availableHeight.isFinite, headerHeight.isFinite, headerHeight >= 0,
              rowHeight.isFinite, rowHeight > 0, spacing.isFinite, spacing >= 0,
              availableHeight > headerHeight, candidateCount > 0 else { return 0 }

        let stride = rowHeight + spacing
        guard stride.isFinite else { return 0 }

        let limit = min(candidateCount, portraitCandidateLimit)
        let fittingRows = (availableHeight - headerHeight) / stride
        return Int(min(Double(limit), fittingRows))
    }
}
