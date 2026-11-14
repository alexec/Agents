import AgentsKitCore
import SwiftUI

/// Gives the views inside it `openWebPlace` (#4937) while this Mac can open the web page, so they
/// draw their links of the Web + Mac link tier, such as Work's **Build trends ↗** (#5180). With no
/// control plane, or no page served, it sets none, and they draw no link. It keeps its own link to
/// the control plane while it is on screen, as Cost does for Open Reports (#4938).
struct WebPlaceLinks: ViewModifier {
    @State private var control: ControlSettingsModel?

    private var shown: Bool {
        guard let control, control.isReachable else { return false }
        return BrowserOpening.linkPage(control.status, onThisMac: control.isOnThisMac) != nil
    }

    func body(content: Content) -> some View {
        content
            .environment(\.openWebPlace, shown ? OpenWebPlace { [control] place in
                guard let control else { return "The control plane can’t be reached." }
                return await control.openInBrowser(place: place)
            } : nil)
            .task {
                guard control == nil, let endpoint = ControlConfig.endpoint,
                      let made = ControlSettingsModel(endpoint: endpoint) else { return }
                control = made
                await made.refresh()
            }
            .onDisappear {
                control?.stop()
                control = nil
            }
    }
}

extension View {
    func webPlaceLinks() -> some View { modifier(WebPlaceLinks()) }
}
