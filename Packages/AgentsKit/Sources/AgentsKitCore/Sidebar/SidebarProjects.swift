import Foundation
import Observation

/// The sidebar's groups (#3278, spec 3273): one per project, not per folder. The folders of
/// one project, on every machine, are one group; a folder in no project is a group alone.
/// A project with one folder looks as that folder did before: the same row, the same name.
///
/// Worked out here once for the window and the Remote; the web page's `projectGroups`
/// (`Web/src/model/sidebar.ts`) is the same.
public enum SidebarProjects {
    /// One group of the sidebar: a project's folders, the main one first.
    public struct Group: Identifiable, Sendable {
        /// The folder the group's row stands for: the one on this machine, or the first in
        /// the sidebar's order. Its fold, menu, pages and workflows are the group's.
        public let main: DaemonAPI.FolderSummary
        /// The project's other folders, in the sidebar's order. Their live sessions are
        /// listed in the group with the main folder's.
        public let others: [DaemonAPI.FolderSummary]

        public var id: FolderKey { main.key }
        /// Every folder of the group, the main one first.
        public var folders: [DaemonAPI.FolderSummary] { [main] + others }
        /// Whether its folders are on more than one machine: only then does a session's
        /// row say its machine.
        public var spansMachines: Bool { others.contains { $0.host != main.host } }
        public var otherKeys: [FolderKey] { others.map(\.key) }

        public init(main: DaemonAPI.FolderSummary, others: [DaemonAPI.FolderSummary] = []) {
            self.main = main
            self.others = others
        }

        /// Whether `key` is one of the group's folders.
        public func holds(_ key: FolderKey) -> Bool {
            folders.contains { $0.host == key.host && $0.folder.folder.standardizedFileURL == key.folder.standardizedFileURL }
        }
    }

    /// `ordered` in `SidebarOrder.folders`' order, gathered by project. Each group stands where
    /// its first folder stands, so the pinned stay first and, in each of the two, the
    /// projects with a folder on this machine come first, as the folders did. `here` is this
    /// machine: the group's main folder is its folder there, when it has one.
    public static func groups(_ ordered: [DaemonAPI.FolderSummary], here: MachineRef = .mac) -> [Group] {
        // Each slot is a folder alone, or the first folder of a project.
        var slots: [(project: String?, folders: [DaemonAPI.FolderSummary])] = []
        var slotOf: [String: Int] = [:]
        for summary in ordered {
            guard let project = summary.project else {
                slots.append((nil, [summary]))
                continue
            }
            if let at = slotOf[project] {
                slots[at].folders.append(summary)
            } else {
                slotOf[project] = slots.count
                slots.append((project, [summary]))
            }
        }
        return slots.map { slot in
            let main = slot.folders.first { $0.host == here } ?? slot.folders[0]
            return Group(main: main, others: slot.folders.filter { $0.key != main.key })
        }
    }

    /// The name the group's row shows. One folder: its own label, `server:Folder` on a
    /// server, as before. Several: the project's name, or the main folder's while the
    /// project's name is not known.
    public static func label(_ group: Group, projectName: String?,
                             hostLabel: (MachineRef) -> String) -> String {
        guard !group.others.isEmpty else { return SidebarOrder.label(group.main, hostLabel: hostLabel) }
        return projectName ?? group.main.name
    }

    /// Each folder's group name, which a smart group's row says after its title: its own
    /// label alone, or its project's name.
    public static func labels(_ groups: [Group], projectName: (String?) -> String?,
                              hostLabel: (MachineRef) -> String) -> [FolderKey: String] {
        var labels: [FolderKey: String] = [:]
        for group in groups {
            let name = label(group, projectName: projectName(group.main.project), hostLabel: hostLabel)
            for folder in group.folders { labels[folder.key] = name }
        }
        return labels
    }

    /// The folder whose connectors the group's Connectors row shows (#3407): the one on this
    /// machine, else the first whose machine answers, else the main one. The repository's
    /// `.agents/mcp.json` is the same in every clone, so any one folder is correct; health is
    /// read on each host, so one that answers says more.
    public static func connectorsFolder(_ group: Group, here: MachineRef = .mac,
                                        isOnline: (MachineRef) -> Bool) -> DaemonAPI.FolderSummary {
        group.folders.first { $0.host == here } ?? group.folders.first { isOnline($0.host) } ?? group.main
    }

    /// What a session's row in the group says after its title: its machine's name, when the
    /// group's folders are on more than one machine and the session is not on this one.
    public static func machineMark(of agent: Agent, in group: Group, here: MachineRef = .mac,
                                   hostLabel: (MachineRef) -> String) -> String? {
        guard group.spansMachines, agent.host != here else { return nil }
        return hostLabel(agent.host)
    }

    /// A folder's machine, as the group's Folders list says it.
    public enum MachineState: String, Sendable {
        case online, offline, stopped
    }

    /// Stopped when its workspace is (#691), offline when it does not answer, else online.
    public static func state(offline: Bool, workspaceState: String?) -> MachineState {
        if workspaceState == "stopped" { return .stopped }
        return offline ? .offline : .online
    }

    /// The group's menu item that lists the project's folders (#3278).
    public static let foldersMenu = "Folders"
    public static let openFolder = "Open Folder"
    public static let folderSettings = "Folder Settings…"

    /// One folder in the Folders list: "Agents — devbox, online".
    public static func folderLine(_ summary: DaemonAPI.FolderSummary, machine: String, state: MachineState) -> String {
        "\(summary.name) — \(machine), \(state.rawValue)"
    }

    /// The project ids that more than one folder shares: the names the sidebar needs.
    public static func sharedProjects(_ groups: [Group]) -> Set<String> {
        Set(groups.filter { !$0.others.isEmpty }.compactMap(\.main.project))
    }
}

/// The names of the projects the sidebar groups (#3278), read from the control plane, which
/// keeps them (#2317). Asked again whenever the set of projects with several folders
/// changes; a project not read yet goes by its main folder's name.
@MainActor
@Observable
public final class ProjectNames {
    public private(set) var names: [String: String] = [:]

    public init() {}

    public func name(of id: String?) -> String? { id.flatMap { names[$0] } }

    /// Reads every project's name. Nothing without a control plane, or with no project to
    /// name; a failed read keeps the names it had.
    public func load(_ ids: Set<String>, from control: DaemonClient?) async {
        guard let control, !ids.isEmpty else { return }
        guard let list = try? await control.call(DaemonAPI.Method.projectsList, DaemonAPI.Empty(),
                                                 returning: DaemonAPI.ProjectList.self) else { return }
        names = Dictionary(list.projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}
