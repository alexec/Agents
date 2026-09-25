import AgentsKit
import SwiftUI

/// Settings ▸ Servers (037, wireframes/mac-settings-servers.svg): each server, how it is
/// doing, and what it is; and the way to add one or take one away.
struct ServersSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var chosen: HostID?
    @State private var isAdding = false
    @State private var removing: HostID?

    var body: some View {
        Form {
            Section {
                if model.hosts.isEmpty {
                    Text("No servers yet. Add one by the name you use with ssh.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.hosts.hosts.all) { host in
                    ServerLine(host: host, isChosen: chosen == host.id,
                               checkAgain: { model.hosts.connect(host.id) },
                               remove: { removing = host.id })
                        .contentShape(Rectangle())
                        .onTapGesture { chosen = host.id }
                }
                HStack {
                    Button {
                        isAdding = true
                    } label: {
                        Label("Add a server", systemImage: "plus")
                    }
                    Spacer()
                }
            } header: {
                Text("Servers")
            } footer: {
                Text("Servers are reached with your own ssh setup. Nothing on them listens on a network port.")
            }
            .paperListRow()
        }
        .paperForm()
        .sheet(isPresented: $isAdding) { AddServerSheet().paperSheet() }
        .sheet(item: $removing) { id in RemoveServerSheet(host: id).paperSheet() }
    }
}

extension HostID: @retroactive Identifiable {
    public var id: String { rawValue }
}

private struct ServerLine: View {
    @Environment(AppModel.self) private var model
    let host: ServerHost
    let isChosen: Bool
    let checkAgain: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(tint.style(or: .secondary)).frame(width: 8, height: 8)
                Text(host.label).fontWeight(.semibold)
                Spacer()
                let count = model.liveProjects.filter { $0.host == host.id }.count
                Text(count == 1 ? "1 project" : "\(count) projects")
                    .appText(.fine).foregroundStyle(.secondary)
            }
            Text(subtitle).appText(.fine).foregroundStyle(.secondary)
            if isChosen {
                HStack {
                    Spacer()
                    Button("Check again", action: checkAgain)
                    Button("Remove…", role: .destructive, action: remove)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }

    private var tint: StateTint {
        switch model.hosts.state(host.id) {
        case .connected: .vouched
        case .offline, .idle, .connecting: .none
        case .updateWaiting: .attention
        case .failed: .failure
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        switch model.hosts.state(host.id) {
        case .offline(let since): parts.append("Offline since \(since.formatted(date: .omitted, time: .shortened))")
        case .updateWaiting: parts.append("Update waiting — an agent is mid-turn")
        case .failed(let problem): parts.append(problem.sentence(name: host.sshName, label: host.label))
        case .connecting: parts.append("Connecting…")
        default: break
        }
        if let facts = host.facts {
            parts.append("\(facts.system) · \(facts.architecture.display)")
            if let version = facts.installedVersion { parts.append("Agents \(version)") }
        }
        let runtimes = model.runtimes(on: host.id).filter { $0.availability.isAvailable }.map(\.runtime.name)
        if !runtimes.isEmpty { parts.append(runtimes.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
}

/// Remove a server (037 US5). Its folders are never touched; what Agents installed goes
/// only if asked.
private struct RemoveServerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let host: HostID
    @State private var purge = false
    @State private var live: Int?
    @State private var isRemoving = false

    private var label: String { model.hosts.label(host) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remove \(label)?").appText(.reading).fontWeight(.semibold)
            let projects = model.liveProjects.filter { $0.host == host }.count
            Group {
                if let live, live > 0 {
                    Text("\(live == 1 ? "1 agent is" : "\(live) agents are") running on \(label) and will be stopped. ")
                        + Text(projectsLine(projects))
                } else {
                    Text(projectsLine(projects))
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Also delete what Agents installed on \(label) (~/.agents-server)", isOn: $purge)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(removeTitle, role: .destructive) {
                    isRemoving = true
                    Task {
                        await model.removeServer(host, purge: purge)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRemoving)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { live = await model.hosts.agentsLive(host) }
    }

    private var removeTitle: String {
        if let live, live > 0 { return "Stop \(live) and Remove" }
        return "Remove"
    }

    private func projectsLine(_ count: Int) -> String {
        "Its \(count == 1 ? "project leaves" : "\(count) projects leave") the list. Your folders on \(label) are not touched."
    }
}
