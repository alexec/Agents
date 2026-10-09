import AgentsKitCore
import SwiftUI

/// One of the rows at the top of the sidebar (#495): Needs You, Working or Unread, across
/// every project and host, folding open on its sessions as a project does. Folded, it
/// reads its count off each project's shelf and lists nothing (#356).
struct SmartFold: View {
    @Environment(AppModel.self) private var model
    let row: SidebarSmartRow
    /// The projects in the sidebar, in its order.
    let projects: [ProjectKey]
    let folds: SidebarFolds
    /// The search's words, already trimmed; empty when there is no search.
    let query: String

    var body: some View {
        let isOpen = folds.isOpen(row)
        let open = Binding(get: { isOpen }, set: { folds.set(row, open: $0) })
        let agents = isOpen ? row.agents(in: model.work, projects: projects, query: query) : []
        DisclosureGroup(isExpanded: open) {
            ForEach(FoldedRow.rows(agents, in: .smart(row))) { item in
                SessionSidebarRow(agent: item.item, place: place(of: item.item))
            }
        } label: {
            SmartRowLabel(row: row, count: row.count(in: model.work, projects: projects))
                .togglesFold(open)
        }
    }

    /// The project's name as its row in the sidebar says it: `server:Project` on a server.
    private func place(of agent: Agent) -> String? {
        guard let summary = model.work.project(ProjectKey(host: agent.host, folder: agent.projectFolder)) else { return nil }
        return SidebarOrder.label(summary) { model.hosts.label($0) }
    }
}

/// A smart row's own line: its symbol, its name, and how many, the count in the
/// attention tint when somebody is waiting and absent at none, so the row stays put.
private struct SmartRowLabel: View {
    let row: SidebarSmartRow
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: row.systemImage)
                .foregroundStyle(row == .needsYou && count > 0 ? StateTint.attention.style(or: .secondary)
                                                               : AnyShapeStyle(.secondary))
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(row.title)
                .lineLimit(1)
                .foregroundStyle(count > 0 ? .primary : .secondary)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .monospacedDigit()
                    .appText(.fine)
                    .foregroundStyle(row == .needsYou ? StateTint.attention.style(or: .secondary)
                                                      : AnyShapeStyle(.secondary))
            }
        }
        .appText(.supporting)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count > 0 ? "\(row.title), \(count)" : "\(row.title), none")
    }
}

/// A row under a project that opens a page about it (#495): its workflows, or its
/// archive. One row each where they used to be folds inside the project's fold.
struct ProjectPageRow: View {
    let title: String
    let systemImage: String
    let count: Int
    let item: SidebarItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(count)")
                .monospacedDigit()
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count)")
        .sidebarInk(item)
        .tag(item)
    }
}

/// The pages about all the work, in the sidebar's toolbar (#495): Events, Resources,
/// Runtimes and Cost, each saying what its row in the list used to — a runtime out, the
/// day's cost and whether it is near its limit.
struct ActivityButtons: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        Button { selection = .events } label: {
            Label("Events", systemImage: "list.bullet.rectangle")
        }
        .help("Events: what happened, what came of it, and who is waiting (⌥⌘E)")
        Button { selection = .resources } label: {
            Label("Resources", systemImage: "square.stack.3d.up")
        }
        .help(resourcesHelp)
        Button { selection = .runtimes } label: {
            Label("Runtimes", systemImage: runtimeIsOut ? "exclamationmark.triangle" : "cpu")
        }
        .foregroundStyle(runtimeIsOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.primary))
        .help(runtimesHelp)
        Button { selection = .spending } label: {
            Text(today ?? "Cost")
                .monospacedDigit()
                .foregroundStyle((model.costState?.dayIsCloseToFull == true ? StateTint.failure : .none)
                    .style(or: .primary))
        }
        .help(today == nil ? "Cost: what all of the work has cost (⌥⌘S)"
                           : "What every agent has cost today. Opens Cost (⌥⌘S)")
    }

    private var tally: RuntimeTally? {
        RuntimeTally(model.runtimes, allowances: model.runtimeAllowances)
    }

    private var runtimeIsOut: Bool { tally?.noneWorking == true }

    private var runtimesHelp: String {
        guard let tally else { return "Runtimes: what each can be started on right now (⌥⌘R)" }
        return "Runtimes: \(tally.words) (⌥⌘R)"
    }

    private var resourcesHelp: String {
        guard let resources = model.leases?.resources else { return "Resources: who holds what, and who is waiting (⌥⌘L)" }
        let held = resources.reduce(0) { $0 + $1.holds.count }
        let waiting = resources.reduce(0) { $0 + $1.line.count }
        return "Resources: \(held) held · \(waiting) waiting (⌥⌘L)"
    }

    /// This Mac's day and every server's, as one figure, as the Cost row had it.
    private var today: String? {
        guard let state = model.costState else { return nil }
        return Cost.total(of: state.today.merging(model.serversToday, uniquingKeysWith: +))
    }
}
