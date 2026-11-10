import AgentsKitCore
import SwiftUI

/// The Plan on an epic's Work page (#3268, spec 3265), in the Work look (#4416,
/// `specs/4328-work-look/epic.md` notes 3 to 11 and 16 to 18): a box above the timeline. Its header
/// has a bar and "4 of 9 done · 2 running · $3.09 spent · about $4.70 to go", then the lead; then
/// the epic's children step by step (`forge/plan` on the machine that read it), a step that is all
/// done folded. A child is the two-line row of parts.md section 2: its state icon, title, level
/// chip and the pull request lineage links to it (`lineage/walk`, `lineage/cost`); under it its
/// number, its mark and what works on it, and its cost or estimate (#3560). A row opens its page;
/// its ⋯ (on hover, and on a right-click) has Blocked by (#3271), Open, Open lane and Open on
/// GitHub. **Add child** is a row that opens the field. A standing epic's plan (#3662) is its
/// query: the labels as chips and the rest in words, then its open issues in one list, the first
/// ten and *N more*, with no steps, Add child or Blocked by. Start lead and Open lead are the
/// page header's.
struct WorkPlanSection: View {
    let model: any WorkModel
    let host: MachineRef
    let lineageHost: MachineRef?
    let detail: DaemonAPI.ForgeItemDetail
    let asked: Int
    /// The epic's open children's estimates (#3560).
    var estimates: [DaemonAPI.LineageEstimate] = []
    let writes: Bool
    let wrote: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var plan: DaemonAPI.ForgePlan?
    @State private var problem: String?
    @State private var rollups: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
    @State private var links: [DaemonAPI.LineageNode: [DaemonAPI.LineageLink]] = [:]
    @State private var said: (words: String, failed: Bool)?
    @State private var adding = false
    @State private var newChild = ""
    @State private var level = "task"
    @State private var busy = false
    @State private var changed = 0
    /// The steps a person folded or opened, until the page is read again.
    @State private var folded: [Int: Bool] = [:]
    /// A standing epic's list past its first ten.
    @State private var all = false
    @FocusState private var childFocused: Bool

    private struct Ask: Equatable {
        var node: DaemonAPI.LineageNode
        var host: MachineRef
        var lineageHost: MachineRef?
        var asked: Int
        var changed: Int
    }

    private var ask: Ask { Ask(node: detail.item.node, host: host, lineageHost: lineageHost, asked: asked, changed: changed) }

    /// Add child and Blocked by: an open epic, not a standing one, on a machine that writes.
    private func changes(_ plan: DaemonAPI.ForgePlan) -> Bool {
        writes && plan.item.state == "open" && plan.standing == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let plan {
                header(plan)
                if let problem {
                    WorkErrorStrip(lines: [problem]) { changed += 1 }
                        .padding(.horizontal, 12).padding(.bottom, 10)
                }
                Group {
                    if let standing = plan.standing { query(standing) }
                    content(plan)
                }
                .opacity(problem == nil ? 1 : 0.5)
            } else if let problem {
                title(standing: detail.item.standing == true).padding([.horizontal, .top], 12)
                couldNotRead(problem)
            } else {
                loading
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.raised))
        .clipShape(RoundedRectangle(cornerRadius: Paper.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
        .workTask(id: ask) { await load() }
        .onChange(of: asked) { folded = [:] }
    }

    // MARK: Header

    /// The glyph and *Plan*; a standing epic's says *never closes* at its end.
    private func title(standing: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: standing ? "arrow.trianglehead.2.clockwise" : "square.stack.3d.up")
                .foregroundStyle(.secondary).accessibilityHidden(true)
            Text("Plan").appText(.reading).fontWeight(.semibold)
            if standing {
                Spacer(minLength: 8)
                Text("never closes").appText(.supporting).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func header(_ plan: DaemonAPI.ForgePlan) -> some View {
        let running = plan.children.filter { child in states(child).contains(where: \.holdsRuntime) }.count
        VStack(alignment: .leading, spacing: 6) {
            if plan.standing != nil {
                title(standing: true)
            } else {
                HStack(spacing: 10) {
                    title(standing: false).fixedSize()
                    let bar = WorkPlan.bar(plan, running: running)
                    WorkBar(parts: [(bar.done, WorkLook.Tone.purple.color), (bar.running, WorkLook.Tone.green.color)])
                        .frame(width: 140)
                    Text(WorkPlan.progressWords(plan, running: running, rollups: Array(rollups.values), estimates: estimates))
                        .appText(.supporting).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                        .textSelection(.enabled)
                }
            }
            leadLine(plan)
        }
        .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 10)
    }

    /// The lead (note 4): its avatar, *Lead*, the session's title (it opens the chat) and its
    /// state in words; with none, *No lead* in grey.
    @ViewBuilder
    private func leadLine(_ plan: DaemonAPI.ForgePlan) -> some View {
        if let lead = plan.lead {
            let title = model.workSessionTitle(lead.session) ?? lead.title
            let state = model.workSessionState(lead.session) ?? lead.state
            HStack(spacing: 6) {
                Circle().fill(WorkLook.Tone.purple.color).frame(width: 18, height: 18)
                    .overlay(Image(systemName: "sparkle").imageScale(.small).foregroundStyle(.white))
                    .accessibilityHidden(true)
                Text("Lead")
                Button(title.map { "“\($0)”" } ?? "A session") { model.openWorkSession(lead.session) }
                    .linkStyle()
                    .disabled(model.workSessionTitle(lead.session) == nil)
                    .help("The lead's chat")
                WorkLeadState(state: state)
            }
            .appText(.supporting)
            .lineLimit(1)
        } else {
            Label("No lead", systemImage: "person").appText(.supporting).foregroundStyle(.secondary)
        }
    }

    /// A standing epic's query (note 17): its labels as chips, then the rest in words, then its
    /// counts; or, with no query, the error from its standing block in a red strip (state 8).
    @ViewBuilder
    private func query(_ standing: DaemonAPI.ForgeStanding) -> some View {
        if let error = standing.error {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon").accessibilityHidden(true)
                Text(error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                if let url = detail.item.url.flatMap(URL.init(string:)) {
                    Button("Edit on \(WorkList.forgeName(detail.item.node.ref))") { openURL(url) }.linkStyle()
                }
            }
            .appText(.supporting)
            .foregroundStyle(WorkLook.Tone.red.color)
            .padding(10)
            .background(WorkLook.Tone.red.color.opacity(0.08))
        } else if let plan {
            let running = plan.children.filter { child in states(child).contains(where: \.holdsRuntime) }.count
            VStack(alignment: .leading, spacing: 6) {
                WrappingHStack(spacing: 6) {
                    Text("Query").foregroundStyle(.secondary)
                    ForEach(standing.labels, id: \.self) { name in
                        WorkLabelChip(label: plan.item.labels.first { $0.name == name } ?? .init(name: name))
                    }
                    Text(WorkPlan.queryRestWords(standing)).foregroundStyle(.secondary)
                }
                Text(WorkPlan.standingWords(plan, running: running, rollups: Array(rollups.values)))
                    .foregroundStyle(.secondary).monospacedDigit()
            }
            .appText(.supporting)
            .padding(.horizontal, 12).padding(.bottom, 10)
            .help("The standing block in this epic's body: its plan is this query, in priority order, then the oldest")
        }
    }

    // MARK: States

    /// The first read (state 1): *Plan*, a grey bar, *No lead*, four placeholder rows.
    private var loading: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                title(standing: false).fixedSize()
                RoundedRectangle(cornerRadius: 3).fill(Paper.wash).frame(width: 200, height: 8)
            }
            Label("No lead", systemImage: "person").appText(.supporting).foregroundStyle(.secondary)
                .redacted(reason: .placeholder)
            Divider()
            WorkPlaceholderRows(count: 4)
        }
        .padding(12)
    }

    /// Nothing read (state 3): in the box, the warning glyph, *Could not read the plan*, the
    /// forge's words and Try again. The rest of the page still shows.
    private func couldNotRead(_ words: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                // The state's own glyph, larger than any text step: a marked decorative glyph.
                .font(.system(size: 22))
                .foregroundStyle(Color(light: 0x9A6700, dark: 0xD29922))
                .accessibilityHidden(true)
            Text("Could not read the plan").fontWeight(.semibold)
            Text(words).appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center).textSelection(.enabled)
            Button(WorkLook.tryAgain) { changed += 1 }.buttonStyle(.paper).padding(.top, 4)
        }
        .padding(.vertical, 24).padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }

    // MARK: Steps

    @ViewBuilder
    private func content(_ plan: DaemonAPI.ForgePlan) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if plan.children.isEmpty {
                if plan.standing?.error == nil { empty(plan) }
            } else if plan.standing != nil {
                band { Text("In order: priority, then the oldest") }
                let shown = all ? plan.children : Array(plan.children.prefix(WorkPlan.standingShown))
                ForEach(shown, id: \.item.node) { child in
                    Divider()
                    row(child, in: plan)
                }
                if !all, let more = WorkPlan.moreWords(plan.children.count) {
                    Divider()
                    Button(more) { all = true }.linkStyle().padding(.horizontal, 12).padding(.vertical, 8)
                }
            } else {
                ForEach(plan.steps, id: \.step) { step in
                    let isFolded = folded[step.step] ?? (WorkPlan.startsFolded(step, in: plan) || plan.item.state == "closed")
                    stepBand(step, in: plan, folded: isFolded)
                    if !isFolded {
                        ForEach(plan.children.filter { $0.step == step.step }, id: \.item.node) { child in
                            Divider()
                            row(child, in: plan)
                        }
                    }
                }
            }
            if changes(plan) {
                Divider()
                addChild(open: plan.children.isEmpty)
            } else if !writes, plan.item.state == "open", plan.standing == nil {
                Divider()
                Text("No machine of yours can write to \(WorkList.forgeName(plan.item.node.ref)).")
                    .appText(.supporting).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Paper.well)
            }
        }
        .overlay(alignment: .top) { Divider() }
    }

    /// No children yet (state 4): what to add, and the Add child field open under it.
    private func empty(_ plan: DaemonAPI.ForgePlan) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(plan.standing == nil ? "No children yet." : "No open issues match its query.").fontWeight(.semibold)
            if changes(plan) {
                Text("Add a story, a task or a spike, or #12 for an issue that is there.")
                    .appText(.supporting).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    /// A band in the fill colour across the box.
    private func band(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 6) { content() }
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Paper.well)
    }

    /// A step's band (notes 5 and 6): a chevron, *Step 2 · waits for #4329*, and its counts at the
    /// end; a click folds or opens it.
    private func stepBand(_ step: DaemonAPI.ForgePlanStep, in plan: DaemonAPI.ForgePlan, folded isFolded: Bool) -> some View {
        let title = WorkPlan.stepTitle(step, in: plan)
        let words = WorkPlan.stepWords(step, in: plan, rollups: rollups)
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { folded[step.step] = !isFolded }
        } label: {
            band {
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isFolded ? 0 : 90))
                    .frame(width: 12)
                    .accessibilityHidden(true)
                stepTitle(title)
                Spacer(minLength: 8)
                Text(words).monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(words)")
        .accessibilityValue(isFolded ? "folded" : "open")
        .help(isFolded ? "Show \(title)" : "Fold \(title)")
    }

    /// *Step 2* in the primary colour and semibold, *· waits for #4329* after it in grey.
    private func stepTitle(_ title: String) -> Text {
        let parts = title.components(separatedBy: " · ")
        let head = Text(parts[0]).fontWeight(.semibold).foregroundStyle(.primary)
        guard parts.count > 1 else { return head }
        return Text("\(head) · \(parts.dropFirst().joined(separator: " · "))")
    }

    private func states(_ child: DaemonAPI.ForgePlanChild) -> [AgentState] {
        WorkPlan.sessions(child.item.node, links: links[child.item.node] ?? [], rollup: rollups[child.item.node])
            .compactMap { model.workSessionState($0) }
    }

    /// The first session that runs on a child, for *Working · “its title”* and Open lane.
    private func lane(_ child: DaemonAPI.ForgePlanChild) -> (id: UUID, title: String)? {
        let ids = WorkPlan.sessions(child.item.node, links: links[child.item.node] ?? [], rollup: rollups[child.item.node])
        let live = ids.first { model.workSessionState($0)?.holdsRuntime == true } ?? ids.first
        guard let live, let title = model.workSessionTitle(live) else { return nil }
        return (live, title)
    }

    private func row(_ child: DaemonAPI.ForgePlanChild, in plan: DaemonAPI.ForgePlan) -> some View {
        let rollup = rollups[child.item.node]
        let pr = WorkPlan.pr(rollup)
        let states = states(child)
        let mark = WorkPlan.mark(child, pr: pr, states: states)
        let lane = lane(child)
        let estimate = estimates.first { $0.node == child.item.node }
        return WorkPlanRow(
            child: child, mark: mark, pr: pr,
            words: WorkPlan.lineWords(child, mark: mark, pr: pr, states: states, lane: lane?.title, in: plan),
            cost: WorkPlan.costWords(rollup),
            estimate: child.item.state == "open" ? estimate.flatMap(WorkPlan.estimateWords) : nil,
            estimateRange: estimate.flatMap(EstimateWords.rangeWords),
            priority: plan.standing == nil ? nil : WorkPlan.priority(child.item),
            open: { model.showWork(WorkPlace(kind: .issue, ref: child.item.node.ref)) },
            openLane: lane.map { lane in { model.openWorkSession(lane.id) } },
            laneTitle: lane?.title,
            openOnForge: child.item.url.flatMap(URL.init(string:)).map { url in { openURL(url) } }
        ) {
            if changes(plan), plan.children.count > 1 { blockedBy(child, in: plan) }
        }
    }

    // MARK: Changing the plan (#3271)

    /// A child's Blocked by: the plan's other children, a tick on each that blocks it now.
    private func blockedBy(_ child: DaemonAPI.ForgePlanChild, in plan: DaemonAPI.ForgePlan) -> some View {
        Section("\(WorkList.shortRef(child.item.node.ref)) is blocked by") {
            ForEach(WorkPlan.blockerChoices(child, in: plan), id: \.child.item.node) { choice in
                Toggle("\(WorkList.shortRef(choice.child.item.node.ref)) \(choice.child.item.title)",
                       isOn: Binding(get: { choice.on }, set: { on in
                           write(DaemonAPI.Method.forgeBlockedBy, WorkPlan.blockedBy(child, choice.child.item.node, on: on))
                       }))
                    .disabled(busy)
            }
        }
    }

    /// Add child (note 11): a row with a + in the accent colour; a click turns it into the field
    /// (*New child's title, or #12*), the level menu and Add. Return adds; Esc closes it. What the
    /// write did stays as a line under it.
    @ViewBuilder
    private func addChild(open: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if adding || open {
                addField(closes: !open)
            } else {
                Button { adding = true; childFocused = true } label: {
                    Label("Add child", systemImage: "plus").foregroundStyle(.tint).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open a new issue as a child of the epic, or make an issue that is there one")
            }
            if let said {
                Text(said.words).appText(.supporting)
                    .foregroundStyle((said.failed ? StateTint.failure : .none).style(or: .secondary))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func addField(closes: Bool) -> some View {
        let names = WorkPlan.namesIssue(newChild)
        return HStack(spacing: 8) {
            TextField("New child's title, or #12", text: $newChild)
                .textFieldStyle(.roundedBorder)
                .focused($childFocused)
                .onSubmit(add)
                #if os(macOS)
                .onExitCommand { if closes { adding = false; newChild = "" } }
                #endif
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
            Button("Add", action: add)
                .buttonStyle(.borderedProminent)
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

    // MARK: Loading

    /// The plan, then each child's cost and links. A read after one came keeps the last plan,
    /// dimmed under the strip, when it fails (state 2).
    private func load() async {
        let mine = ask
        if mine.changed == 0 { said = nil }
        let got: DaemonAPI.ForgePlan
        do {
            got = try await model.forge(DaemonAPI.Method.forgePlan, DaemonAPI.ForgePlanRequest(node: mine.node),
                                        returning: DaemonAPI.ForgePlan.self, on: host)
        } catch {
            guard ask == mine else { return }
            problem = WorkList.failureWords(error)
            return
        }
        guard ask == mine else { return }
        plan = got
        problem = nil
        guard let lineageHost else { rollups = [:]; links = [:]; return }
        // Each child's cost and links: the links name a lane at once, the cost once it banked a turn.
        var found: [DaemonAPI.LineageNode: DaemonAPI.LineageCostRollup] = [:]
        var linked: [DaemonAPI.LineageNode: [DaemonAPI.LineageLink]] = [:]
        await withTaskGroup(of: (DaemonAPI.LineageNode, DaemonAPI.LineageCostRollup?, [DaemonAPI.LineageLink]?).self) { group in
            for child in got.children {
                let node = child.item.node
                group.addTask {
                    async let cost = model.lineageCost(node, on: lineageHost)
                    async let walk = try? model.lineageWalk(node, depth: LineageList.depth, on: lineageHost)
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

/// A child of the Plan (epic.md note 7), the two-line row of parts.md section 2. Line 1: the state
/// icon, the title, the level chip, and at the end the pull request lineage links to it. Line 2:
/// the number, the mark and its words (the attention colour and semibold for Needs you, red for
/// blocked outside the plan), and at the end the cost, or the estimate in the tertiary colour. The
/// ⋯ shows on hover and keyboard focus; a right-click opens the same menu.
private struct WorkPlanRow<BlockedBy: View>: View {
    let child: DaemonAPI.ForgePlanChild
    let mark: WorkPlan.Mark
    let pr: DaemonAPI.LineageCostNode?
    let words: String?
    let cost: String?
    let estimate: String?
    let estimateRange: String?
    let priority: DaemonAPI.ForgeLabel?
    let open: () -> Void
    let openLane: (() -> Void)?
    let laneTitle: String?
    let openOnForge: (() -> Void)?
    @ViewBuilder let blockedBy: BlockedBy

    @State private var hovered = false
    @FocusState private var focused: Bool

    private var ref: String { WorkList.shortRef(child.item.node.ref) }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Button(action: open) {
                // One element with one label, inside the button so it keeps its role: the chips have their own.
                label.contentShape(Rectangle()).accessibilityElement(children: .ignore).accessibilityLabel(accessibilityWords)
            }
            .buttonStyle(.plain)
            .focused($focused)
            .help("Open \(ref)'s page")
            Menu { menu } label: { Image(systemName: "ellipsis") }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovered || focused ? 1 : 0)
                .help("More for \(ref)")
                .accessibilityLabel("More for \(ref)")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovered ? Paper.well.opacity(0.6) : .clear)
        .onHover { hovered = $0 }
        .contextMenu { menu }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            WorkStateIcon(kind: "issue", state: child.item.state).frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text.forgeTitle(child.item.title).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                        .layoutPriority(1)
                    if let level = child.item.level {
                        WorkLabelChip(label: child.item.labels.first { $0.name.lowercased() == level } ?? .init(name: level))
                            .fixedSize()
                    }
                    Spacer(minLength: 8)
                    if let pr {
                        HStack(spacing: 3) {
                            WorkStateIcon(kind: "pr", state: pr.outcome ?? "open")
                            Text(WorkList.shortRef(pr.node.ref)).monospacedDigit()
                        }
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 4) {
                    line
                    Spacer(minLength: 8)
                    if let priority { WorkLabelChip(label: priority).fixedSize() }
                    if let cost {
                        Text(cost).monospacedDigit().foregroundStyle(.secondary)
                    } else if let estimate {
                        Text(estimate).monospacedDigit().foregroundStyle(.tertiary).help(estimateRange ?? "")
                    }
                }
                .appText(.fine)
            }
        }
    }

    /// *#4333 · ● Working · “Work look: epic page”*: the number, then the mark in its colour and its words.
    private var line: some View {
        HStack(spacing: 4) {
            Text(ref).monospacedDigit().foregroundStyle(.secondary)
            if let words {
                Text("·").foregroundStyle(.secondary)
                Group {
                    if let glyph = glyph { Image(systemName: glyph).imageScale(.small) }
                    Text(words).lineLimit(1).truncationMode(.tail)
                }
                .foregroundStyle(tint)
                .fontWeight(mark == .attention ? .semibold : .regular)
            }
        }
    }

    private var glyph: String? {
        switch mark {
        case .done: nil
        case .working: "circle.fill"
        case .attention: "exclamationmark.triangle"
        case .waiting: "circle"
        case .blocked: "nosign"
        }
    }

    private var tint: Color {
        switch mark {
        case .working: WorkLook.Tone.green.color
        case .attention: Color(light: 0x9A6700, dark: 0xD29922)
        case .blocked: WorkLook.Tone.red.color
        case .done, .waiting: .secondary
        }
    }

    @ViewBuilder
    private var menu: some View {
        blockedBy
        Button("Open \(ref)", action: open)
        if let openLane, let laneTitle { Button("Open lane “\(laneTitle)”", action: openLane) }
        if let openOnForge { Button(WorkList.openOnWords(child.item.node.ref), action: openOnForge) }
    }

    private var accessibilityWords: String {
        var parts = [WorkLook.glyph(kind: "issue", state: child.item.state)?.accessibilityLabel, child.item.title, child.item.level]
        if let pr { parts.append("pull request \(WorkList.shortRef(pr.node.ref)) \(pr.outcome ?? "open")") }
        parts.append(ref)
        parts.append(mark == .done ? words : [mark.words, words].compactMap { $0 }.joined(separator: ", "))
        parts.append(priority?.name)
        parts.append(cost ?? estimate.map { "estimate \($0)" })
        return parts.compactMap { $0 }.joined(separator: ", ")
    }
}

/// A lead's state in words after a dot (epic.md note 4): green while it works, the attention colour
/// when it needs you, grey otherwise.
struct WorkLeadState: View {
    let state: AgentState

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(WorkPlan.leadWords(state)).foregroundStyle(state == .waitingOnUser ? color : .secondary)
        }
    }

    private var color: Color {
        switch state {
        case .waitingOnUser: Color(light: 0x9A6700, dark: 0xD29922)
        case .starting, .running: WorkLook.Tone.green.color
        default: Color.secondary.opacity(0.5)
        }
    }
}

/// A thin bar of parts on a grey track (the Plan's header, a feature, an epic's mini row): each
/// part a share from 0 to 1 in its colour, one after the other.
struct WorkBar: View {
    let parts: [(Double, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    Rectangle().fill(part.1).frame(width: geo.size.width * min(max(part.0, 0), 1))
                }
                Spacer(minLength: 0)
            }
            .background(Paper.wash)
            .clipShape(Capsule())
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}
