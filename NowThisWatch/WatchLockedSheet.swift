import SwiftUI

struct WatchLockedSheet: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "lock.circle").font(.title2).accessibilityHidden(true)
            Text("NowThis Supporter").font(.headline)
            Text(verbatim: String(
                localized: "watch.locked.body",
                defaultValue: "Viewing tasks is always free. For editing, open Settings → Support Development on your iPhone.",
                comment: "Shown on the watch when an edit is attempted without NowThis Supporter. The arrow is a navigation path on the iPhone; use whatever separator your language's own Settings paths use. Its spoken twin spells the same path out in words, because VoiceOver cannot read an arrow — the two are deliberately different and must stay that way."))
                .font(.footnote).multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            localized: "watch.locked.a11y",
            defaultValue: "Viewing tasks is always free. To unlock Apple Watch task editing, open Settings, Support Development, on your iPhone.",
            comment: "VoiceOver label for the locked sheet on the watch. Spoken, not shown — the Settings path is spelled out with commas rather than the arrow the visible label uses, because VoiceOver cannot read an arrow. Name the Settings app whatever it is called in your language."))
    }
}
