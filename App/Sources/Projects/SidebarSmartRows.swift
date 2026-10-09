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
            if row == .pinned {
                if isOpen { pinnedRows }
            } else {
                ForEach(FoldedRow.rows(agents, in: .smart(row))) { item in
                    SessionSidebarRow(agent: item.item, place: place(of: item.item))
                }
            }
        } label: {
            SmartRowLabel(row: row, count: row.count(in: model.work, projects: projects))
                .togglesFold(open)
        }
    }

    /// Every project's pinned sessions, then its pinned workflows, each dragged into the
    /// order wanted among its own project's and its own kind (#180, #432).
    @ViewBuilder
    private var pinnedRows: some View {
        let searching = !query.isEmpty
        ForEach(projects, id: \.self) { key in
            let sessions = SidebarSmartRow.pinned.agents(in: model.work, projects: [key], query: query)
            ForEach(FoldedRow.rows(sessions, in: .smart(.pinned))) { item in
                SessionSidebarRow(agent: item.item, place: place(of: item.item))
            }
            // The whole order, which a search shows only some of.
            .onMove { from, to in
                guard !searching else { return }
                var ids = sessions.map(\.id)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedSessions(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeSessionPins(ids + rest, in: key) }
            }
            let flows = SidebarSmartRow.pinned.workflows(in: model.work, projects: [key], query: query).map(\.workflow)
            ForEach(FoldedRow.rows(flows, in: .smart(.pinned))) { item in
                WorkflowListRow(summary: item.item, project: key)
            }
            .onMove { from, to in
                guard !searching else { return }
                var ids = flows.map(\.workflowID)
                ids.move(fromOffsets: from, toOffset: to)
                let shown = Set(ids)
                let rest = model.pinnedWorkflows(in: key.folder).filter { !shown.contains($0) }
                Task { await model.arrangeWorkflowPins(ids + rest, in: key) }
            }
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
        // No icon (Alex, #495): the sessions under it carry the marks.
        HStack(spacing: 6) {
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
        // The size of the rows around it, sessions and New Session alike.
        .appText(.supporting)
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
        // An icon, in the group with the others (Alex, #495); the day's figure is its help,
        // and it turns red when the day is close to its limit.
        Button { selection = .spending } label: {
            Label(today.map { "Cost, \($0) today" } ?? "Cost", systemImage: "dollarsign.circle")
        }
        .foregroundStyle((model.costState?.dayIsCloseToFull == true ? StateTint.failure : .none)
            .style(or: .primary))
        .help(today.map { "Cost: \($0) today (⌥⌘S)" } ?? "Cost: what all of the work has cost (⌥⌘S)")
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
