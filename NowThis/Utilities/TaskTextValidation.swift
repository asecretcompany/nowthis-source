import Foundation

/// Entry validation only. Imported models and unchanged legacy fields are never rewritten.
enum TaskTextValidation {
    enum Failure: Error, LocalizedError, CustomLocalizedStringResourceConvertible {
        case title, notes, rawInput
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .title: "The title is too long. Use up to 500 characters and shorten unusually complex characters."
            case .notes: "The notes are too long. Use up to 20,000 characters and shorten unusually complex characters."
            case .rawInput: "This task input is too large. Shorten it and try again."
            }
        }
        var errorDescription: String? { String(localized: localizedStringResource) }
    }

    static func title(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= TaskItem.maxTitleBytes,
              trimmed.count <= TaskItem.maxTitleLength else { throw Failure.title }
        return trimmed
    }

    static func notes(_ value: String?) throws {
        guard let value else { return }
        guard value.utf8.count <= TaskItem.maxNotesBytes,
              value.count <= TaskItem.maxNotesLength else { throw Failure.notes }
    }

    static func quickAdd(_ raw: String, now: Date = Date(),
                         calendar: Calendar = .current) throws -> NaturalLanguageParser.ParseResult {
        guard raw.utf8.count <= TaskItem.maxQuickAddBytes else { throw Failure.rawInput }
        return NaturalLanguageParser.parse(raw, now: now, calendar: calendar)
    }
}
