import SwiftUI

/// How wide a column of text is allowed to get.
///
/// The Mac keeps the transcript inside a 144pt gutter. A phone has no room for one and
/// does not need one — 390 points is already a readable measure — but a 13-inch iPad
/// in landscape gives the conversation 800 points, and a line that long is one the eye
/// loses its place on between the end of it and the start of the next.
///
/// So it is a ceiling rather than a gutter: nothing is inset until there is more room
/// than the text can use, and then the surplus goes either side.
extension View {
    func readableWidth() -> some View {
        frame(maxWidth: 620)
            .frame(maxWidth: .infinity, alignment: .center)
    }
}
