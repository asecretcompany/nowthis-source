import Foundation

// Presentation copy lives outside the locale-free iCalendar wire parser.
extension ICalendarParser.WorkLimitExceeded: LocalizedError {
    var errorDescription: String? {
        String(localized: "A server task is too complex to process safely. Sync stopped before importing that task.",
               comment: "Recovery message when a remote task exceeds parser work limits. No task contents or credentials are included.")
    }
}
