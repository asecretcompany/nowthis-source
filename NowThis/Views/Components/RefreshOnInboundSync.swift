import SwiftUI

extension View {
    /// The screen keeps its identity. Its `InboundQueryReader` refreshes only the data boundary.
    func refreshOnInboundSync() -> some View { self }
}
