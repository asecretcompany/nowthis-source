import SwiftUI

/// Circular progress indicator that fills based on percentage.
///
/// Used in task detail view to show PERCENT-COMPLETE visually.
struct ProgressRingView: View {

    let progress: Double
    let lineWidth: CGFloat
    let size: CGFloat

    init(progress: Double, lineWidth: CGFloat = 3, size: CGFloat = 24) {
        self.progress = min(1.0, max(0.0, progress))
        self.lineWidth = lineWidth
        self.size = size
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    progressColor,
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: progress)
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100)) percent")
    }

    private var progressColor: Color {
        if progress >= 1.0 { return .green }
        if progress >= 0.5 { return .blue }
        return .orange
    }
}

#Preview {
    HStack(spacing: 20) {
        ProgressRingView(progress: 0.0)
        ProgressRingView(progress: 0.25)
        ProgressRingView(progress: 0.5)
        ProgressRingView(progress: 0.75)
        ProgressRingView(progress: 1.0)
    }
}
