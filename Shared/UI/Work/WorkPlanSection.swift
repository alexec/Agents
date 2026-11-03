import AgentsKitCore
import SwiftUI

/// The Plan section on an epic's Work page (#3268, spec 3265), as the web page's `WorkPlan`: the
/// epic's children step by step (`forge/plan` on the machine that read it), each with its mark,
/// level, issue, the lane and PR that work on it and its cost (from lineage, `lineage/walk` and
/// `lineage/cost`); a
/// header with the lead, the children done and running, and the total cost; and **Start lead**
/// (the `lead` skill's form, in the epic's folder) or **Open lead**. A row opens its issue's page.
struct WorkPlanSection: View {
    let model: any WorkModel
    let host: MachineRef
    let lineageHost: MachineRef?
    let detail: DaemonAPI.ForgeItemDetail
    let asked: Int

    @State private var plan: DaemonAPI.ForgePlan?
    @State private var problem: String?
    @State private var rollups: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
    @State private var links: [DaemonAPI.LineageNode: [DaemonAPI.LineageLink]] = [:]
    @State private var said: String?

    private struct Ask: Equatable {
        var node: DaemonAPI.LineageNode
        var host: MachineRef
        var lineageHost: MachineRef?
        var asked: Int
    }

    private var ask: Ask { Ask(node: detail.item.node, host: host, lineageHost: lineageHost, asked: asked) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("Plan").appText(.reading).fontWeight(.semibold)
            if let plan {
                header(plan)
                if plan.children.isEmpty {
                    Text("No sub-issues yet.").foregroundStyle(.secondary)
                } else {
                    steps(plan)
                }
            } else if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .workTask(id: ask) { await load() }
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ plan: DaemonAPI.ForgePlan) -> some View {
        let running = plan.children.filter { child in
            states(child).contains(where: \.holdsRuntime)
        }.count
        WrappingHStack(spacing: 12) {
            if let lead = plan.lead {
                Text(WorkPlan.leadWords(lead, title: model.workSessionTitle(lead.session)))
                    .foregroundStyle((lead.state == .waitingOnUser ? StateTint.attention : .none).style(or: .primary))
            } else {
                Text("No lead").foregroundStyle(.secondary)
            }
            Text(WorkPlan.progressWords(plan, running: running, rollups: Array(rollups.values)))
                .monospacedDigit().foregroundStyle(.secondary)
            if let lead = plan.lead {
                Button("Open lead") { model.openWorkSession(lead.session) }
                    .disabled(model.workSessionTitle(lead.session) == nil)
                    .help("The lead's chat")
            } else if let start = detail.start, plan.item.state == "open" {
                Button("Start lead") { startLead(start) }
                    .buttonStyle(.borderedProminent)
                    .help("The new-session form in this epic's folder, filled in for a lead with the lead skill")
            }
        }
        if let said {
            Text(said).appText(.supporting).foregroundStyle(StateTint.failure.style(or: .secondary))
        }
    }

    private func startLead(_ start: DaemonAPI.ForgeStart) {
        guard let folder = detail.item.folder else {
            said = "No folder on this machine is on this issue's repo."
            return
        }
        let lead = WorkPlan.leadStart(start, url: detail.item.url)
        let offer = AppViewStart(prompt: lead.prompt, labels: lead.labels, worktree: lead.worktree)
        said = model.offerStart(offer, in: FolderKey(host: host, folder: URL(fileURLWithPath: folder)))
    }

    // MARK: Steps

    @ViewBuilder
    private func steps(_ plan: DaemonAPI.ForgePlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(plan.steps, id: \.step) { step in
                Text(WorkPlan.stepTitle(step, in: plan))
                    .appText(.supporting).fontWeight(.semibold).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5))
                ForEach(plan.children.filter { $0.step == step.step }, id: \.item.node) { child in
                    row(child)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private func states(_ child: DaemonAPI.ForgePlanChild) -> [AgentState] {
        WorkPlan.sessions(child.item.node, links: links[child.item.node] ?? [], rollup: rollups[child.item.node])
            .compactMap { model.workSessionState($0) }
    }

    @ViewBuilder
    private func row(_ child: DaemonAPI.ForgePlanChild) -> some View {
        let rollup = rollups[child.item.node]
        let pr = WorkPlan.pr(rollup)
        let states = states(child)
        let mark = WorkPlan.mark(child, pr: pr, states: states)
        Button {
            model.showWork(WorkPlace(kind: .issue, ref: child.item.node.ref))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(mark.rawValue).foregroundStyle(tint(mark)).frame(width: 16)
                    .help(mark.words).accessibilityLabel(mark.words)
                Text(child.item.level ?? "").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                Text(WorkList.shortRef(child.item.node.ref)).foregroundStyle(.secondary).monospacedDigit()
                Text(child.item.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if let words = WorkPlan.workWords(pr: pr, states: states) ?? WorkPlan.blockedWords(child) {
                    Text(words).foregroundStyle(.secondary).lineLimit(1)
                }
                if let cost = WorkPlan.costWords(rollup) {
                    Text(cost).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(WorkList.shortRef(child.item.node.ref))'s page")
    }

    private func tint(_ mark: WorkPlan.Mark) -> AnyShapeStyle {
        switch mark {
        case .done: return StateTint.vouched.style(or: .secondary)
        case .attention: return StateTint.attention.style(or: .secondary)
        case .working: return AnyShapeStyle(.primary)
        case .waiting, .blocked: return AnyShapeStyle(.secondary)
        }
    }

    // MARK: Loading

    private func load() async {
        let mine = ask
        problem = nil
        said = nil
        let got: DaemonAPI.ForgePlan
        do {
            got = try await model.forge(DaemonAPI.Method.forgePlan, DaemonAPI.ForgePlanRequest(node: mine.node),
                                        returning: DaemonAPI.ForgePlan.self, on: host)
        } catch {
            guard ask == mine else { return }
            plan = nil
            problem = error.localizedDescription
            return
        }
        guard ask == mine else { return }
        plan = got
        guard let lineageHost else { rollups = [:]; links = [:]; return }
        // Each child's cost and links: the links name a lane at once, the cost once it banked a turn.
        var found: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
        var linked: [DaemonAPI.LineageNode: [DaemonAPI.LineageLink]] = [:]
        await withTaskGroup(of: (DaemonAPI.LineageNode, DaemonAPI.LineageCostRollup?, [DaemonAPI.LineageLink]?).self) { group in
            for child in got.children {
                let node = child.item.node
                group.addTask {
                    async let cost = model.lineageCost(node, on: lineageHost)
                    async let walk = try? model.lineageWalk(node, on: lineageHost)
                    return await (node, cost, walk?.links)
                }
            }
            for await (node, rollup, walked) in group {
                found[node] = rollup
                linked[node] = walked
            }
        }
        guard ask == mine else { return }
        rollups = found
        links = linked
    }
}
