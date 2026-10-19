import Foundation

/// What Return does in the prompt, the same in the window, the Remote and the web page
/// (#377): Return sends, and Shift-Return and Option-Return are a line break (#1514).
///
/// A hardware keyboard's rule. The iPhone's and iPad's on-screen keyboard keeps Return
/// as a new line, with Send as the button, and never asks.
public enum PromptReturn: Equatable, Sendable {
    /// Sent, or the command or mention on offer taken.
    case send
    /// A new line in the field, and nothing sent.
    case lineBreak

    /// Shift or Option breaks the line, as in most places a message is written (#1514).
    public init(option: Bool, shift: Bool) {
        self = option || shift ? .lineBreak : .send
    }
}
