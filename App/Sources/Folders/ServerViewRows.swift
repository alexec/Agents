import AgentsKitCore
import SwiftUI

/// A connected server's list views (#2032), after the folder's pins and before its
/// sessions: a row each, named by the service ("GitHub · Issues"), without a pin. A row
/// opens as a pinned view does; its menu hides it, and the folder's menu shows it again.
struct ServerViewRows: View {
    @Environment(AppModel.self) private var model
    let folder: FolderKey

    var body: some View {
        ForEach(model.serverViews(in: folder.folder).filter { $0.hidden != true }) { view in
            ServerViewRow(view: view, folder: folder)
        }
    }
}

private struct ServerViewRow: View {
    @Environment(AppModel.self) private var model
    let view: PinView
    let folder: FolderKey

    var body: some View {
        HStack(spacing: 6) {
            // As a pinned view's row (#155): plain text beside a plain image.
            Image(systemName: "square.grid.2x2")
                .sidebarMark(Paper.accent)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(view.title)
                .lineLimit(1)
            Spacer(minLength: 4)
            // Its server's count (#2033), grey as a heading's count.
            if let count = view.count {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .appText(.supporting)
        .padding(.vertical, 2)
        .listRowInsets(.vertical, 2)
        .help(view.countHelp.map { "\(view.path)\n\($0)" } ?? view.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(view.title), view" + (view.count.map { ", \($0)" } ?? ""))
        .sidebarInk(.pin(view.path, in: folder))
        .tag(SidebarItem.pin(view.path, in: folder))
        .contextMenu {
            Button("Open") { model.showPin(view.path, in: folder) }
            Divider()
            Button("Hide") { Task { await model.setViewHidden(view.path, true, in: folder) } }
        }
    }
}

/// The folder menu's Show Hidden Views (#2032): every server view hidden in the folder,
/// back in the sidebar. Left out when none is hidden.
struct ShowHiddenViewsButton: View {
    @Environment(AppModel.self) private var model
    let folder: FolderKey

    var body: some View {
        let hidden = model.serverViews(in: folder.folder).filter { $0.hidden == true }
        if !hidden.isEmpty {
            Button("Show Hidden Views (\(hidden.count))") {
                Task {
                    for view in hidden { await model.setViewHidden(view.path, false, in: folder) }
                }
            }
            .disabled(model.hostUnreachable(folder.host))
        }
    }
}
