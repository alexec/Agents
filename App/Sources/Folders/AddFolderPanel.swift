import AgentsKitCore
import AppKit
import SwiftUI

/// File ▸ Add Folder… on this Mac: the system's folder panel, with the Add Folder sheet's
/// Project under it (#2671), as `RemoteFolderSheet` has it for a server. The projects are
/// read before the panel opens; with none, or no control plane, the panel is as it was.
@MainActor
enum AddFolderPanel {
    static func choose(control: DaemonClient?) async -> (folder: URL, project: String?)? {
        let projects = await NewFolderProjectChoice.projects(on: control)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        let picked = Picked()
        if !projects.isEmpty {
            let accessory = NSHostingView(rootView: Accessory(projects: projects, picked: picked))
            accessory.frame.size = accessory.fittingSize
            panel.accessoryView = accessory
            panel.isAccessoryViewDisclosed = true
        }
        let answer = await withCheckedContinuation { done in panel.begin { done.resume(returning: $0) } }
        guard answer == .OK, let folder = panel.url else { return nil }
        return (folder, picked.project)
    }

    @Observable
    final class Picked {
        var project: String?
    }

    struct Accessory: View {
        let projects: [DaemonAPI.Project]
        @Bindable var picked: Picked

        var body: some View {
            NewFolderProjectChoice(projects: projects, project: $picked.project)
                .padding(12)
                .frame(width: 460, alignment: .leading)
        }
    }
}
