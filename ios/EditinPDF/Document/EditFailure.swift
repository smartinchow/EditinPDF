import EditinPDFCore
import Foundation
import os

/// What the reader is told about a change that was not made: an alert's title and its message.
///
/// Always our sentences, from `Strings`, never the engine's text, which is English, technical, and
/// may name the inside of the file. That text goes to the private log instead. The message is empty
/// when there is nothing more to say than the title.
struct EditFailure: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "edit")

    init(_ error: Error) {
        title = Strings.editFailed
        message = Self.message(for: error)
        Self.log.error("change refused: \(String(describing: error), privacy: .private)")
    }

    /// A refusal that is not the engine's: `message` is one of our sentences.
    init(message: String) {
        title = Strings.editFailed
        self.message = message
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? EditError else { return "" }
        switch error {
        case .ReadOnly, .NotPermitted:
            return Strings.editNotAllowed
        case .WouldRemoveAllPages:
            return Strings.cannotDeleteAllPages
        case .Stale:
            return Strings.documentChangedTryAgain
        case .SourceNeedsPassword:
            return Strings.insertSourceLocked
        case .SourceUnreadable:
            return Strings.insertSourceUnreadable
        case .SourceNotPermitted:
            return Strings.insertSourceNotPermitted
        case .Invalid, .NothingToUndo, .NothingToRedo, .Failed:
            return ""
        }
    }
}
