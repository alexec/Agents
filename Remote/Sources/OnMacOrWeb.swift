import AgentsKitCore
import SwiftUI

/// Where a Mac + web feature was (#2796, #2798): "Open this on your Mac or the web page", with the
/// web page's `page` a tap away when the control plane serves one. A row: it goes in a Form, a
/// List or a stack.
struct OnMacOrWeb: View {
    @Environment(RemoteModel.self) private var model
    /// The web page's route, without `#/`: `settings`, `reports`, `console/audit`.
    let page: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(MacOrWebWords.line).appText(.supporting).foregroundStyle(.secondary)
            if let url = MacOrWebWords.url(model.controlStatus, page: page) {
                Link(MacOrWebWords.openWebPage, destination: url).appText(.supporting)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
