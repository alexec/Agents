import AgentsKitCore
import SwiftUI

extension Text {
    /// An issue's or a pull request's title as the forge draws it: its code spans in the
    /// code face, the rest as it was written (`ForgeMarkdown.titleParts`).
    /// A static function, not an init: an init taking one string makes `map(Text.init)` ambiguous.
    static func forgeTitle(_ title: String) -> Text {
        var text = AttributedString()
        for part in ForgeMarkdown.titleParts(title) {
            var piece = AttributedString(part.text)
            if part.code { piece.inlinePresentationIntent = .code }
            text.append(piece)
        }
        return Text(text)
    }
}
