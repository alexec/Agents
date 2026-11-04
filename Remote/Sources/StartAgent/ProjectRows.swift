import AgentsKitCore
import SwiftUI

/// New Session's first two choices (#3279): the **project**, then the machine it is **on**,
/// as the Mac's page and the web page have them. A project with one folder hides On, so it
/// looks as a folder does today. Adding a folder on another machine is Mac + web (#2798).
struct ProjectRows: View {
    @Environment(RemoteModel.self) private var model
    let folder: URL

    var body: some View {
        let projects = model.newSessionProjects
        if let summary = model.work.folder(folder), let current = NewSessionProject.choice(of: summary.key, in: projects) {
            Section {
                projectRow(projects, current: current, summary: summary)
                if !current.hidesMachine {
                    machineRow(current, summary: summary)
                }
            }
            .paperListRow()
        }
    }

    private func projectRow(_ projects: [NewSessionProject.Choice], current: NewSessionProject.Choice,
                            summary: DaemonAPI.FolderSummary) -> some View {
        Menu {
            ForEach(projects) { project in
                Button {
                    model.showProject(project)
                } label: {
                    choiceLabel(label(project), chosen: project.id == current.id)
                }
            }
        } label: {
            LabeledContent("Project") {
                Text(label(current)).foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .accessibilityLabel("Project, \(label(current))")
    }

    private func machineRow(_ project: NewSessionProject.Choice, summary: DaemonAPI.FolderSummary) -> some View {
        Menu {
            ForEach(project.folders, id: \.self) { key in
                Button {
                    model.sidebarItem = .folder(key)
                } label: {
                    choiceLabel(machine(key, in: project), chosen: key == summary.key)
                    if let state = state(key.host) { Text(state) }
                }
            }
        } label: {
            LabeledContent("On") {
                Text(model.hostLabel(summary.host)).foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .accessibilityLabel("On, \(model.hostLabel(summary.host))")
    }

    /// A project with one folder is named as its folder is today: `server:Name` when the
    /// folder is on a server. One with folders on several machines is named alone.
    private func label(_ project: NewSessionProject.Choice) -> String {
        guard project.hidesMachine, let folder = model.work.folder(project.folders.first) else { return project.name }
        return SidebarOrder.label(folder) { model.hostLabel($0) }
    }

    /// The machine's name, with the path when the project has two folders on it.
    private func machine(_ key: FolderKey, in project: NewSessionProject.Choice) -> String {
        let name = model.hostLabel(key.host)
        guard project.folders.filter({ $0.host == key.host }).count > 1 else { return name }
        return "\(name) · \(key.folder.path(percentEncoded: false))"
    }

    /// `Stopped, starts when used` or `Offline`; nothing for a machine that answers.
    private func state(_ host: MachineRef) -> String? {
        if model.startsWhenUsed(host) { return "Stopped, starts when used" }
        if model.hostIsOffline(host) { return "Offline" }
        return nil
    }

    @ViewBuilder
    private func choiceLabel(_ title: String, chosen: Bool) -> some View {
        if chosen { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}
