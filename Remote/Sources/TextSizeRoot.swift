import SwiftUI

extension TextSize {
    /// Where the phone keeps the choice (#750). Its own app's defaults, so nothing else
    /// shares it, and never sent to the Mac.
    static let defaultsKey = "textSize"
}

extension View {
    /// The person's text size over the whole app (#750): the system's Dynamic Type moved
    /// up a step or two, so their own setting is built on rather than replaced, and the
    /// size itself for the marks drawn beside text.
    func chosenTextSize() -> some View {
        modifier(ChosenTextSize())
    }
}

private struct ChosenTextSize: ViewModifier {
    @AppStorage(TextSize.defaultsKey) private var stored = TextSize.standard
    @Environment(\.dynamicTypeSize) private var system

    func body(content: Content) -> some View {
        let size = TextSize.launchOverride ?? stored
        content
            .dynamicTypeSize(size.applied(to: system))
            .environment(\.textSize, size)
    }
}
