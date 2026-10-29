import SwiftUI

/// Tells the user, in the language they are actually reading, that this translation is
/// machine-made — and gives them somewhere to report it when it reads badly.
///
/// Presented once per language (see ``TranslationDisclosure``) and permanently reachable from
/// Settings afterwards, because a disclosure the user can never find again is a formality.
///
/// The layout is deliberate. This is a multi-paragraph sheet, which is the exact shape that
/// shipped broken in an earlier app of ours: `presentationDetents` with no `ScrollView` compressed every
/// paragraph to one line and truncated with ellipses, while the accessibility tree still carried
/// the full text — so it read correctly to VoiceOver and showed a sighted user three dots. Hence
/// the `ScrollView` and the `.fixedSize(horizontal: false, vertical: true)` on every paragraph,
/// present from the first commit rather than added after a screenshot caught it.
struct TranslationDisclosureSheet: View {
    /// Called when the user dismisses. The caller records the acknowledgement here — on dismiss,
    /// never on present, so a sheet the user never actually saw does not count as read.
    var onAcknowledge: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "character.bubble")
                        .font(.largeTitle)
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)

                    Text(verbatim: String(
                        localized: "disclosure.translation.body",
                        defaultValue: "NowThis is written in English. The other languages were translated by AI as part of building the app — nothing you type is ever sent to an AI service. Some wording may still be wrong, or correct but unnatural.",
                        comment: "Body of the sheet shown once per language telling the user this translation was made by AI. Shown in the language being described, so write it as a plain statement about the text the reader is looking at. Two things must survive translation exactly: that the AI was used while BUILDING the app, not while running it, and that the user's own data never reaches an AI service. 'as part of building the app' is the load-bearing phrase — 'this app uses AI' would be a different and untrue claim. 'NowThis' is a product name and is never translated."))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(verbatim: String(
                        localized: "disclosure.translation.invitation",
                        defaultValue: "If something reads badly, telling us is the fastest way to get it fixed.",
                        comment: "Second paragraph of the machine-translation disclosure sheet, inviting the user to report bad wording. Keep it short and non-apologetic — it is an invitation, not a disclaimer."))
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.secondary)

                    if let url = TranslationDisclosure.reportURL {
                        Button {
                            openURL(url)
                        } label: {
                            Label(String(
                                localized: "disclosure.translation.report",
                                defaultValue: "Report a translation problem",
                                comment: "Button on the machine-translation disclosure sheet that opens the support page. 'Report' is a VERB — the action the user takes — not the noun for a document. The object is a problem with the wording, not a problem with the app."),
                                  systemImage: "exclamationmark.bubble")
                        }
                        .accessibilityHint(String(
                            localized: "disclosure.translation.report.a11y.hint",
                            defaultValue: "Opens the support page in your browser.",
                            comment: "VoiceOver hint on the button that opens the support page from the translation disclosure sheet. Spoken, not shown."))
                    }
                }
                .padding()
            }
            .navigationTitle(String(
                localized: "disclosure.translation.title",
                defaultValue: "About this translation",
                comment: "Title of the sheet explaining that this translation is machine-made, and the label of the Settings row that reopens it. A heading, not a sentence: 'this translation' means the text the reader is currently looking at."))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(
                        localized: "disclosure.translation.dismiss",
                        defaultValue: "Continue",
                        comment: "Button that dismisses the machine-translation disclosure sheet. A VERB, and the only action on the sheet — it acknowledges having read it and closes. Not 'Next' (nothing follows) and not 'OK' if your language distinguishes them. Toolbar buttons are narrow: keep it to one short word.")) {
                        onAcknowledge()
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

#Preview {
    TranslationDisclosureSheet(onAcknowledge: {})
}
