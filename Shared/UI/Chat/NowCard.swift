import AgentsKitCore
import SwiftUI

/// The Now family of session cards (#5033, `specs/session-cards/spec.md`, family 5): what
/// the agent works towards, at the top, and what it does or waits on now, at the foot.
/// Both are a card on the well with the same parts: a mark, a bold line and a quiet
/// detail, a meta on the right, a chevron when it has more, and a bar when there is a
/// deadline or a count. No colour fills it: the bar is the accent (Paper v2).
///
/// The web page draws the same in `Web/src/views/Now.tsx`, with the words of
/// `Web/src/model/nowWords.ts`.
enum NowWords {
    static let working = "Working"
    static let showMore = "Show more"
    static let showLess = "Show less"

    /// "In the background · 2", the foot's line when only background work is left.
    static func background(_ count: Int) -> String { "In the background · \(count)" }

    /// The plan's one line in the transcript (#5033): "Plan · 5 steps", or "Plan, dropped ·
    /// 5 steps" for a withdrawn one. It opens to the steps as they were then.
    static func plan(_ plan: Plan) -> String {
        let steps = plan.entries.count == 1 ? "1 step" : "\(plan.entries.count) steps"
        return plan.state == .withdrawn ? "Plan, dropped · \(steps)" : "Plan · \(steps)"
    }
}

extension EnvironmentValues {
    /// Whether the Now card around a part is open, and the way to open it. Nil outside one:
    /// a part drawn alone shows all it has and no chevron.
    @Entry var nowOpen: Binding<Bool>? = nil
    /// Whether the Now card has anything more to show when it is opened.
    @Entry var nowHasMore = false
}

/// A Now card's head: mark, what in bold, a quiet detail, the meta on the right, and the
/// chevron when the card has more. The whole row opens and closes it.
struct NowHead<Mark: View>: View {
    let title: String
    var detail: String?
    var meta: String?
    /// A meta that its detail says again, so it shows only while the card is closed.
    var closedMeta: String?
    @ViewBuilder let mark: () -> Mark

    @Environment(\.nowOpen) private var open
    @Environment(\.nowHasMore) private var hasMore

    var body: some View {
        if let open, hasMore {
            Button {
                withAnimation(ResponseMotion.response) { open.wrappedValue.toggle() }
            } label: {
                row(chevron: open.wrappedValue)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(open.wrappedValue ? NowWords.showLess : NowWords.showMore)
        } else {
            row(chevron: nil)
        }
    }

    private func row(chevron isOpen: Bool?) -> some View {
        HStack(alignment: .center, spacing: 8) {
            mark()
                .frame(width: 18)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(title)
                    .fontWeight(.semibold)
                    .layoutPriority(1)
                if let detail {
                    Text(" · " + detail)
                        .foregroundStyle(.secondary)
                }
            }
            .appText(.supporting)
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 8)
            if let meta = meta ?? (isOpen == true ? nil : closedMeta) {
                Text(meta)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            if let isOpen {
                Image(icon: "chevron.right")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// How far along, as a thin bar in the accent: a plan's steps, a goal's budget, a wait's
/// deadline.
struct NowBar: View {
    let fraction: Double

    var body: some View {
        Capsule()
            .fill(Paper.rule)
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Capsule()
                        .fill(Paper.accent)
                        .frame(width: proxy.size.width * min(max(fraction, 0), 1))
                }
            }
            .accessibilityHidden(true)
    }
}

/// The Now card's well, the same at the top and the foot.
private struct NowWell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paperWell(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
    }
}

/// What the agent works towards, at the head of the chat (#5033): the goal (#2742) and the
/// plan in force (#341) as one card with two rows. Each row opens on its own. It was two
/// strips of the same shape.
struct NowTopCard: View {
    let agent: Agent

    var body: some View {
        if agent.goal != nil || agent.planInForce != nil {
            VStack(alignment: .leading, spacing: 0) {
                if let goal = agent.goal {
                    GoalRow(goal: goal)
                }
                if agent.goal != nil, agent.planInForce != nil {
                    Paper.rule.frame(height: 1)
                        .padding(.vertical, 8)
                }
                if let plan = agent.planInForce {
                    PlanRow(plan: plan)
                }
            }
            .modifier(NowWell())
            .topEdges()
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .background(Paper.ground)
        }
    }
}

/// What the agent does or waits on now, the last thing before the prompt bar (#5033): the
/// working line, the wait, or the live picture when it drives the screen. What it holds in
/// a lease and what runs in the background are its detail, so each is said once.
///
/// `parts` are the cards each app builds that are not Asks: the live tile, a wait on
/// sessions and the agent's wait on events. Each draws its own `NowHead`; with none, the
/// card draws the working line. When the agent is not running and none is left, the card
/// goes and the quiet line is in its place.
struct NowCard: View {
    let agent: Agent
    let isComingBack: Bool
    let parts: [WaitingCard]
    let leases: LeaseStatus?
    let capacityStart: String?
    let background: BackgroundActions
    var openLease: ((ResourceName) -> Void)?

    /// The person's choice; nil follows the card: open while it shows a live picture.
    @State private var chosen: Bool?

    private var running: [BackgroundItem] { agent.background.filter(\.isRunning) }
    private var isWorking: Bool { agent.state == .running || agent.state == .starting }
    private var hasDetail: Bool { leases != nil || !running.isEmpty }

    /// Whether there is anything to say now.
    var isShown: Bool {
        !parts.isEmpty || isComingBack || isWorking || capacityStart != nil || hasDetail
    }

    var body: some View {
        if isShown {
            let isOpen = chosen ?? parts.contains { $0.id.hasPrefix("live:") }
            VStack(alignment: .leading, spacing: 10) {
                if parts.isEmpty {
                    head
                } else {
                    ForEach(parts) { $0.view }
                }
                if isOpen, hasDetail {
                    if let leases {
                        LeaseLine(status: leases, open: openLease)
                    }
                    ForEach(running) { item in
                        BackgroundItemRow(item: item, actions: background, stacked: isCompact)
                    }
                }
            }
            .modifier(NowWell())
            .environment(\.nowOpen, Binding(get: { isOpen }, set: { chosen = $0 }))
            .environment(\.nowHasMore, hasDetail || !parts.isEmpty)
        }
    }

    /// The card's own line when no part says more: coming back, working, a queued start,
    /// or only what it holds or runs in the background.
    @ViewBuilder private var head: some View {
        if isComingBack {
            NowHead(title: AgentsModel.comingBackDescription, closedMeta: summary) {
                Image(icon: AgentsModel.comingBackSymbol).foregroundStyle(.secondary)
            }
        } else if isWorking {
            let tool = RunningToolWords.tool(agent)
            NowHead(title: agent.state == .starting ? AgentState.startingLabel : NowWords.working,
                    detail: tool, closedMeta: summary) {
                // The one working mark on the page, in step with the sidebar row (#2044, #2831).
                WorkingRing(size: 16, doing: tool != nil)
            }
            .accessibilityLabel(tool.map(RunningToolWords.label) ?? NowWords.working)
        } else if let capacityStart {
            NowHead(title: capacityStart, closedMeta: summary) {
                Image(icon: "clock").foregroundStyle(.secondary)
            }
        } else if let leases, running.isEmpty {
            NowHead(title: leases.lines.first ?? leases.fullLine) {
                Image(icon: "lock").foregroundStyle(.secondary)
            }
        } else {
            NowHead(title: NowWords.background(running.count), closedMeta: leases?.lines.first) {
                Image(icon: "layers").foregroundStyle(.secondary)
            }
        }
    }

    /// The meta of the card's own line: the first lease, else how much runs in the background.
    private var summary: String? {
        leases?.lines.first ?? (running.isEmpty ? nil : NowWords.background(running.count))
    }

    private var isCompact: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
}

/// The goal's row in the top card: its objective and where it stands; a stopped goal says
/// why under it; a budget is a bar. A goal is not a status, so its word is grey. Its words
/// are `Goal.statusWord`, `progressLine` and `summary`, as the web page's.
private struct GoalRow: View {
    let goal: Goal
    @State private var isExpanded = false

    var body: some View {
        Button {
            openOrClose($isExpanded)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(icon: goal.status == .complete ? "checkmark.circle" : "scope")
                        .appText(.supporting)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    Text(goal.objective)
                        .appText(.supporting)
                        .fontWeight(.semibold)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Text(goal.statusWord)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    chevron(isExpanded)
                }
                if let reason = goal.reason, goal.isStopped || isExpanded {
                    Text(reason)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                        .multilineTextAlignment(.leading)
                        .padding(.leading, 26)
                }
                if isExpanded, let progress = goal.progressLine {
                    Text(progress)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .padding(.leading, 26)
                }
                if let fraction = goal.budgetFraction {
                    NowBar(fraction: fraction)
                        .padding(.top, 2)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(goal.summary)
        .accessibilityHint(isExpanded ? "Shows the goal on one line" : "Shows the whole goal")
    }
}

/// The plan's row in the top card: the step being worked and how far along, opened to
/// every step. Which plan, and its words, are `Agent.planInForce`, `Plan.stripStep` and
/// `Plan.stripDone`, as the web page's.
private struct PlanRow: View {
    let plan: Plan
    @State private var isExpanded = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                openOrClose($isExpanded)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(icon: "checkmark.square")
                            .appText(.supporting)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        Text(plan.stripStep)
                            .appText(.supporting)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 8)
                        Text(count)
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .fixedSize()
                        chevron(isExpanded)
                    }
                    NowBar(fraction: Double(plan.stripDone) / Double(max(plan.entries.count, 1)))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(plan.stripSummary)
            .accessibilityHint(isExpanded ? "Hides the plan's steps" : "Shows the plan's steps")

            if isExpanded {
                PlanView(plan: plan)
                    .padding(.top, 8)
            }
        }
    }

    /// "2 of 5", or "2/5" where a phone's width is short of it.
    private var count: String {
        #if os(iOS)
        if sizeClass == .compact { return "\(plan.stripDone)/\(plan.entries.count)" }
        #endif
        return "\(plan.stripDone) of \(plan.entries.count)"
    }
}

/// The plan as the agent sent it, in the transcript (#5033): one line, "Plan · 5 steps",
/// that opens to the steps as they were then. The plan as it is now is in the top card.
struct PlanLine: View {
    let plan: Plan

    var body: some View {
        RecordLine(icon: LineGlyph.plan, detail: NowWords.plan(plan),
                   openHelp: ("Show the plan's steps", "Hide the plan's steps")) {
            PlanView(plan: plan)
        }
    }
}

/// Opens or closes a row of the top card. On the Mac it is not animated (#5189): the card
/// is the chat's top safe-area inset, and an animated inset re-measured the transcript's
/// scroll view on every frame of the animation. While a turn ran, AppKit's layout pass
/// then never settled ("more Update Constraints in Window passes than there are views"),
/// and the window quit. The chevron still turns with the motion; a rotation changes no
/// layout. On the phone and iPad the inset is UIKit's, which settles, so it eases there.
@MainActor
private func openOrClose(_ isOpen: Binding<Bool>) {
    #if os(macOS)
    isOpen.wrappedValue.toggle()
    #else
    withAnimation(ResponseMotion.response) { isOpen.wrappedValue.toggle() }
    #endif
}

@MainActor
private func chevron(_ isOpen: Bool) -> some View {
    Image(icon: "chevron.right")
        .appText(.fine)
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isOpen ? 90 : 0))
        .animation(ResponseMotion.response, value: isOpen)
        .accessibilityHidden(true)
}

private extension View {
    /// The window's chat column, where the top card sits; the phone's own margin.
    @ViewBuilder
    func topEdges() -> some View {
        #if os(macOS)
        chatColumn()
        #else
        padding(.horizontal, 16)
        #endif
    }
}
