import AgentsKitCore
import SwiftUI

/// A folder's pinned pages (#159), first in its fold of the sidebar, right under the
/// folder's own row: the folder's pages together, then its sessions. Rows tagged into the sidebar's one selection, so a pin opens in the chat's
/// place as a session does, and dragged among themselves to re-order them.
///
/// Left out for a folder with none.
struct PinnedPageRows: View {
    @Environment(AppModel.self) private var model
    let folder: FolderKey

    var body: some View {
        let pins = model.pins(in: folder.folder)
        ForEach(pins) { pin in
            PinnedPageRow(pin: pin, folder: folder, pins: pins)
        }
        // Among the pins only: a ForEach's move never crosses into the sessions below.
        .onMove { from, to in
            var paths = pins.map(\.path)
            paths.move(fromOffsets: from, toOffset: to)
            Task { await model.arrangePins(paths, in: folder) }
        }
    }
}

private struct PinnedPageRow: View {
    @Environment(AppModel.self) private var model
    let pin: PinView
    let folder: FolderKey
    let pins: [PinView]

    var body: some View {
        HStack(spacing: 6) {
            // Plain text beside a plain image, not a Label: a sidebar draws a Label's
            // title in its own style, and the row must read as the sessions do (#155).
            Image(systemName: pin.kind == .view ? "square.grid.2x2" : pin.kind == .html ? "globe" : "doc.text")
                .sidebarMark(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(pin.title)
                .lineLimit(1)
                .foregroundStyle(pin.missing ? .secondary : .primary)
            // Nothing at its end (#587), which is only a session's: missing is the grey
            // title and the tooltip's why.
            Spacer(minLength: 4)
        }
        .appText(.supporting)
        .padding(.vertical, 2)
        .listRowInsets(.vertical, 2)
        .help(pin.missingReason.map { "\(pin.path): \($0)" } ?? pin.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pin.title), pinned \(pin.kind == .view ? "view" : "page")" + (pin.missing ? ", missing" : ""))
        .sidebarInk(.pin(pin.path, in: folder))
        .tag(SidebarItem.pin(pin.path, in: folder))
        .contextMenu {
            Button("Open") { model.showPin(pin.path, in: folder) }
            Divider()
            Button("Move Up") { step(-1) }
                .disabled(pins.first?.path == pin.path)
            Button("Move Down") { step(1) }
                .disabled(pins.last?.path == pin.path)
            Divider()
            Button("Unpin") { Task { await model.unpin(pin.path, in: folder) } }
        }
    }

    private func step(_ by: Int) {
        var paths = pins.map(\.path)
        guard let index = paths.firstIndex(of: pin.path), paths.indices.contains(index + by) else { return }
        paths.swapAt(index, index + by)
        Task { await model.arrangePins(paths, in: folder) }
    }
}
