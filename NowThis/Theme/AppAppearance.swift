import SwiftUI

/// User-selectable appearance preference, persisted via `@AppStorage`.
///
/// `.system` defers to the device's Light/Dark setting (the default); `.light`
/// and `.dark` force a specific scheme app-wide via `preferredColorScheme`.
/// The picker lives in `SettingsView`; the root modifier is applied in `ContentView`.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    /// `@AppStorage` key shared between the settings picker and the root view.
    static let storageKey = "appAppearance"

    var id: String { rawValue }

    /// The SwiftUI color scheme to force, or `nil` to follow the device setting.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// A user-facing localized name for the appearance picker.
    var displayName: String {
        switch self {
        case .system: return String(localized: "System")
        case .light:  return String(localized: "Light")
        case .dark:   return String(localized: "Dark")
        }
    }

    /// SF Symbol shown alongside the option in the picker.
    var systemImageName: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light:  return "sun.max"
        case .dark:   return "moon"
        }
    }
}
