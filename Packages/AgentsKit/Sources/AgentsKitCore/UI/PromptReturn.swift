import Foundation

/// What Return does in the prompt, the same in the window, the Remote and the web page
/// (#377): Return and Shift-Return send, and only Option-Return is a line break.
///
/// A hardware keyboard's rule. The iPhone's and iPad's on-screen keyboard keeps Return
/// as a new line, with Send as the button, and never asks.
public enum PromptReturn: Equatable, Sendable {
    /// Sent, or the command or mention on offer taken.
    case send
    /// A new line in the field, and nothing sent.
    case lineBreak

    /// Shift makes no difference: it sends, as Return does.
    public init(option: Bool, shift: Bool = false) {
        self = option ? .lineBreak : .send
    }
}
