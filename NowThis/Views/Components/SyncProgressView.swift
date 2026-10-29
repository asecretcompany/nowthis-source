import SwiftUI

struct SyncProgressView: View {
    @Environment(SyncProgressState.self) private var progressState

    var body: some View {
        if let progress = progressState.current {
            let phase = phaseText(for: progress.stage)
            let count = progress.total.map {
                String(localized: "sync.progress.count",
                       defaultValue: "\(progress.completed) of \($0)",
                       comment: "Completed/total progress ratio. The progress phase supplies the task noun.")
            }

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)

                Text(phase)
                    .font(.subheadline)

                if let count {
                    Text(count)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(Text(phase))
            .accessibilityValue(Text(count ?? ""))
        }
    }

    private func phaseText(for stage: SyncProgress.Stage) -> String {
        switch stage {
        case .discovering:
            String(localized: "sync.progress.phase.discovering",
                   defaultValue: "Checking lists…",
                   comment: "Sync progress phase while discovering lists.")
        case .inventory:
            String(localized: "sync.progress.phase.inventory",
                   defaultValue: "Checking tasks…",
                   comment: "Sync progress phase while checking task inventory.")
        case .downloading:
            String(localized: "sync.progress.phase.downloading",
                   defaultValue: "Downloading tasks…",
                   comment: "Sync progress phase while downloading tasks.")
        case .applying:
            String(localized: "sync.progress.phase.applying",
                   defaultValue: "Saving tasks…",
                   comment: "Sync progress phase while saving downloaded tasks.")
        case .finishing:
            String(localized: "sync.progress.phase.finishing",
                   defaultValue: "Finishing sync…",
                   comment: "Sync progress phase while completing sync.")
        }
    }
}

#Preview {
    let progressState = SyncProgressState()
    progressState.apply(.init(accountID: "preview", listID: nil, stage: .downloading,
                              completed: 12, total: 24))
    return SyncProgressView()
        .environment(progressState)
        .padding()
}
