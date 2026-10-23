import SwiftUI

extension EnvironmentValues {
    /// True inside a sidebar row the window draws on the accent (#2382). The Mac sets it
    /// (`SidebarInk`), because its sidebar tells no row; the Remote's list says it by
    /// `backgroundProminence`.
    @Entry var sidebarRowInked = false

    /// The row under this view is filled with the accent: its marks are the ground there.
    var drawsOnAccent: Bool {
        sidebarRowInked || backgroundProminence == .increased
    }
}

/// A mark's own colour, except on a row filled with the accent, where it is the ground
/// as the text is (#2382): an accent mark there is blue on blue, as Finder and Mail
/// never draw one, and the orange one is hard to read on cobalt too.
private struct SidebarMarkStyle<S: ShapeStyle>: ViewModifier {
    let style: S
    @Environment(\.drawsOnAccent) private var onAccent

    func body(content: Content) -> some View {
        content.foregroundStyle(onAccent ? AnyShapeStyle(Paper.ground) : AnyShapeStyle(style))
    }
}

extension View {
    /// A mark's colour in place of `foregroundStyle`, for marks a sidebar row draws.
    func sidebarMark<S: ShapeStyle>(_ style: S) -> some View {
        modifier(SidebarMarkStyle(style: style))
    }
}

/// The microphone on the session voice mode listens in (#2518). Accent, and the ground
/// on a row filled with the accent (#2382). The row draws it only while
/// `VoiceMode.isOn(in:)` is true for that session, so it moves with the chat and goes
/// when voice mode ends.
struct ListeningMark: View {
    var body: some View {
        Image(systemName: "mic.fill")
            .appText(.fine)
            .sidebarMark(Paper.accent)
            .help("Voice mode listens in this chat")
            .accessibilityLabel("Listening")
    }
}
