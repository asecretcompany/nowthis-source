import Foundation

/// Decides when to tell the user that the app's translations are machine-made.
///
/// ## Once per language, not once ever
///
/// The obvious spec is "show it once" — it describes how the app was built, and that does not
/// change. In practice that is wrong. A user reading German dismisses the sheet, later switches
/// the device to Italian, and is disclosed nothing: the sheet they acknowledged **was written in
/// German**, and the Italian they are now reading has never been disclosed at all. So the
/// acknowledgement is per language, and the set is what persists.
///
/// Regions fold into their language (`de-AT` → `de`): Austrian German reads the same catalog as
/// German German, so acknowledging one acknowledges the other. Folding at the *language* subtag
/// rather than comparing whole identifiers is what stops the sheet reappearing every time a user
/// moves between `de-DE` and `de-CH`.
///
/// ## Deliberate details
///
/// - **English never fires.** English is the source language; nothing about it was translated.
///   This also makes the bundle gate self-enforcing: an app built without its non-English
///   `.lproj` folders resolves to `en`, and a disclosure about translations that are not in the
///   build would be a lie.
/// - **Recorded on dismiss, not on present.** A sheet killed by a crash, a backgrounded app or a
///   deep link has not been read. Recording on present would silently consume the one chance.
/// - **Nothing is migrated from a boolean.** There has never been a boolean here, and if there
///   ever is, the right migration is *none* — let everyone see it once more in the language they
///   are actually reading, which is the correct behaviour rather than a concession.
/// - **Gated on onboarding.** Showing this over the welcome screen would be the first thing a new
///   user ever sees.
enum TranslationDisclosure {

    /// `@AppStorage` key. The value is the encoded acknowledged-language set.
    static let storageKey = "translationDisclosureAcknowledgedLanguages"

    /// Where "report a translation problem" goes.
    ///
    /// Pinned in one place on purpose — it ships inside five translations, and B4 in the
    /// localization plan has not yet confirmed it. One constant to change if it is wrong.
    static let reportURLString = "https://asc.is/support/"

    static var reportURL: URL? { URL(string: reportURLString) }

    /// The language subtag of a BCP-47 identifier: `de-AT` → `de`, `zh-Hans-CN` → `zh`.
    ///
    /// Lowercased, because `Bundle` and `Locale` disagree about case often enough that a
    /// `Set<String>` keyed on raw identifiers would treat `DE` and `de` as two languages.
    static func fold(_ identifier: String) -> String {
        let cut = identifier.prefix { $0 != "-" && $0 != "_" }
        return cut.lowercased()
    }

    /// The language the *built app* resolved to, which is not always the device's first choice:
    /// a German device running a build with no `de.lproj` gets `en` here, and correctly sees no
    /// disclosure.
    static var currentLanguage: String {
        fold(Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// Decodes the stored set. Order is not meaningful; blanks are dropped so a stray separator
    /// cannot register as an acknowledged language named "".
    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map { fold(String($0)) }.filter { !$0.isEmpty })
    }

    /// Encodes sorted, so the stored value is stable and a diff of it means something.
    static func encode(_ languages: Set<String>) -> String {
        languages.sorted().joined(separator: ",")
    }

    /// Whether the disclosure is owed for this language right now.
    static func shouldPresent(
        language: String,
        acknowledged: Set<String>,
        hasCompletedOnboarding: Bool
    ) -> Bool {
        guard hasCompletedOnboarding else { return false }
        guard language != "en" else { return false }
        return !acknowledged.contains(language)
    }

    /// The set after the user dismisses the sheet in `language`.
    static func acknowledging(_ language: String, in acknowledged: Set<String>) -> Set<String> {
        acknowledged.union([fold(language)])
    }
}
