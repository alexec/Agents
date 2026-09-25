import AgentsKit
import SwiftUI

/// A host's heading in the project list (037, wireframes/mac-projects.svg): its name,
/// and how it is doing in a dot and at most two words.
struct HostHeading: View {
    @Environment(AppModel.self) private var model
    let host: HostID

    var body: some View {
        HStack(spacing: 6) {
            Text(model.hosts.label(host).uppercased())
            if host != .mac { mark }
        }
    }

    @ViewBuilder
    private var mark: some View {
        switch model.hosts.state(host) {
        case .connected:
            dot(.green)
        case .connecting, .idle:
            ProgressView().controlSize(.mini)
        case .offline(let since):
            dot(.gray)
            Text("Offline · \(since.formatted(date: .omitted, time: .shortened))")
                .textCase(nil).foregroundStyle(.secondary)
        case .updateWaiting:
            dot(.orange)
            Text("Update waiting").textCase(nil).foregroundStyle(.secondary)
        case .failed:
            dot(.red)
            Text("Can’t connect").textCase(nil).foregroundStyle(.secondary)
        }
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }
}
