import AgentsKitCore
import SwiftUI

/// The Plan section on an epic's Work page (#3268, spec 3265), as the web page's `WorkPlan`: the
/// epic's children step by step (`forge/plan` on the machine that read it), each with its mark,
/// level, issue, the lane and PR that work on it and its cost (from lineage, `lineage/walk` and
/// `lineage/cost`); a
/// header with the lead, the children done and running, and the total cost; and **Start lead**
/// (the `lead` skill's form, in the epic's folder) or **Open lead**. A row opens its issue's page.
/// Where the machine writes to the forge, the plan changes here too (#3271): **Add child** (a new
/// issue, or one that is there) under the steps, and each row's **Blocked by** menu of the other
/// children; `wrote` reads the page again.
struct WorkPlanSection: View {
    let model: any WorkModel
    let host: MachineRef
    let lineageHost: MachineRef?
    let detail: DaemonAPI.ForgeItemDetail
    let asked: Int
    let writes: Bool
    let wrote: () -> Void

    @State private var plan: DaemonAPI.ForgePlan?
    @State private var problem: String?
    @State private var rollups: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
    @State private var links: [DaemonAPI.LineageNode: [DaemonAPI.LineageLink]] = [:]
    @State private var said: (words: String, failed: Bool)?
    @State private var newChild = ""
    @State private var level = "task"
    @State private var busy = false
    @State private var changed = 0

    private struct Ask: Equatable {
        var node: DaemonAPI.LineageNode
        var host: MachineRef
        var lineageHost: MachineRef?
        var asked: Int
        var changed: Int
    }

    private var ask: Ask { Ask(node: detail.item.node, host: host, lineageHost: lineageHost, asked: asked, changed: changed) }

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
                if writes, plan.item.state == "open" { addChild }
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
            Text(said.words).appText(.supporting)
                .foregroundStyle((said.failed ? StateTint.failure : .none).style(or: .secondary))
                .textSelection(.enabled)
        }
    }

    private func startLead(_ start: DaemonAPI.ForgeStart) {
        guard let folder = detail.item.folder else {
            said = ("No folder on this machine is on this issue's repo.", true)
            return
        }
        let lead = WorkPlan.leadStart(start, url: detail.item.url)
        let offer = AppViewStart(prompt: lead.prompt, labels: lead.labels, worktree: lead.worktree)
        said = model.offerStart(offer, in: FolderKey(host: host, folder: URL(fileURLWithPath: folder))).map { ($0, true) }
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
                    HStack(spacing: 0) {
                        row(child)
                        if writes, plan.children.count > 1 { blockedByMenu(child, in: plan) }
                    }
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

    // MARK: Changing the plan (#3271)

    /// A child's Blocked by: the plan's other children, a tick on each that blocks it now.
    private func blockedByMenu(_ child: DaemonAPI.ForgePlanChild, in plan: DaemonAPI.ForgePlan) -> some View {
        Menu {
            Section("Blocked by") {
                ForEach(WorkPlan.blockerChoices(child, in: plan), id: \.child.item.node) { choice in
                    Toggle("\(WorkList.shortRef(choice.child.item.node.ref)) \(choice.child.item.title)",
                           isOn: Binding(get: { choice.on }, set: { on in
                               write(DaemonAPI.Method.forgeBlockedBy, WorkPlan.blockedBy(child, choice.child.item.node, on: on))
                           }))
                }
            }
        } label: {
            Text("Blocked by").appText(.supporting)
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
        .padding(.trailing, 10)
        .disabled(busy)
        .help("Blocked by: which children \(WorkList.shortRef(child.item.node.ref)) waits for")
    }

    /// Add child: a new issue's title with its level, or #12 / ENG-4 for one that is there.
    private var addChild: some View {
        let names = WorkPlan.namesIssue(newChild)
        return HStack(spacing: 8) {
            TextField("New child's title, or #12 for an issue that is there", text: $newChild)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
                .accessibilityLabel("Child")
            Picker("Level", selection: $level) {
                ForEach(WorkPlan.childLevels, id: \.self) { level in
                    Text(level.isEmpty ? "No level" : level.capitalized).tag(level)
                }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(names)
            .help(names ? "An issue that is there keeps its labels" : "The new child's level")
            Button("Add child", action: add)
                .disabled(busy || newChild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help(names ? "Make this issue a child of the epic" : "Open a new issue as a child of the epic, in its feature")
            if busy { ProgressView().controlSize(.small) }
        }
    }

    private func add() {
        guard !newChild.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        write(DaemonAPI.Method.forgeAddChild, WorkPlan.addChild(detail.item.node, words: newChild, level: level)) {
            newChild = ""
        }
    }

    private func write(_ method: String, _ params: some Encodable & Sendable, then: @escaping () -> Void = {}) {
        Task {
            busy = true
            defer { busy = false }
            do {
                let done = try await model.forge(method, params, returning: DaemonAPI.ForgeDone.self, on: host)
                then()
                changed += 1
                said = (WorkList.doneWords(method, done), false)
                wrote()
            } catch {
                said = (error.localizedDescription, true)
            }
        }
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
        if mine.changed == 0 { said = nil }
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
