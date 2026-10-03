import AgentsKitCore
import SwiftUI

/// A project's pinned pages (#159), first in its fold of the sidebar, right under the
/// project's own row, which opens the Dashboard: the project's pages together, then its
/// sessions. Rows tagged into the sidebar's one selection, so a pin opens in the chat's
/// place as a session does, and dragged among themselves to re-order them.
///
/// Left out for a project with none.
struct PinnedPageRows: View {
    @Environment(AppModel.self) private var model
    let project: ProjectKey

    var body: some View {
        let pins = model.pins(in: project.folder)
        ForEach(pins) { pin in
            PinnedPageRow(pin: pin, project: project, pins: pins)
        }
        // Among the pins only: a ForEach's move never crosses into the sessions below.
        .onMove { from, to in
            var paths = pins.map(\.path)
            paths.move(fromOffsets: from, toOffset: to)
            Task { await model.arrangePins(paths, in: project) }
        }
    }
}

private struct PinnedPageRow: View {
    @Environment(AppModel.self) private var model
    let pin: PinView
    let project: ProjectKey
    let pins: [PinView]

    var body: some View {
        HStack(spacing: 6) {
            // Plain text beside a plain image, not a Label: a sidebar draws a Label's
            // title in its own style, and the row must read as the sessions do (#155).
            Image(systemName: pin.kind == .html ? "globe" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(pin.title)
                .lineLimit(1)
                .foregroundStyle(pin.missing ? .secondary : .primary)
            Spacer(minLength: 4)
            if pin.missing {
                Text("Missing")
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.body)
        .padding(.vertical, 2)
        .listRowInsets(.vertical, 2)
        .help(pin.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pin.missing ? "\(pin.title), pinned page, missing" : "\(pin.title), pinned page")
        .tag(SidebarItem.pin(pin.path, in: project))
        .contextMenu {
            Button("Open") { model.showPin(pin.path, in: project) }
            Divider()
            Button("Move Up") { step(-1) }
                .disabled(pins.first?.path == pin.path)
            Button("Move Down") { step(1) }
                .disabled(pins.last?.path == pin.path)
            Divider()
            Button("Unpin") { Task { await model.unpin(pin.path, in: project) } }
        }
    }

    private func step(_ by: Int) {
        var paths = pins.map(\.path)
        guard let index = paths.firstIndex(of: pin.path), paths.indices.contains(index + by) else { return }
        paths.swapAt(index, index + by)
        Task { await model.arrangePins(paths, in: project) }
    }
}
