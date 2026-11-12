#if os(macOS)
import AgentsKitCore
import AppKit
import Observation
import SwiftUI

/// Work ▸ Timeline's state (#4173): the range, the project and board, and what `work/timeline` read
/// for the time around the window. The model keeps it, so Back from an issue's page finds the
/// Timeline as it was left.
@MainActor
@Observable
final class WorkTimelineState {
    var range: WorkTimeline.Range = .twoDays
    /// The project, by id; "" until one is picked, then the first one.
    var project = ""
    /// The board the epics are narrowed to (#3282), by its url; "" for every board.
    var board = ""
    var boards: [DaemonAPI.ProjectBoard] = []
    /// Where the window is: Now, until the plot is scrolled past an edge.
    var anchor = Date.now
    var timeline: DaemonAPI.WorkTimeline?
    var problem: String?
    /// A read runs: the toolbar's Refresh spins.
    var reading = false
    /// The last read got nothing: the plot is the read before it, dimmed under the strip (S12).
    var stale = false
    var asked = 0
    /// Now was clicked: the plot scrolls back to it.
    var nowAsked = 0
    /// Children that closed since the last read, and when they were seen: their dots pulse once.
    var landed: [String: Date] = [:]
    /// Every machine's sessions on the epics and their children, from the control plane's merged
    /// copy (#4276): a sleeping machine's sessions still start their children.
    var sessions: [DaemonAPI.LineageSessionOn] = []
    private var read: Ask?
    /// The machines' timelines as one, before the sessions start their children.
    private var fromMachines: DaemonAPI.WorkTimeline?

    struct Ask: Equatable {
        var asked: Int
        var project: String
        var board: String
        var range: WorkTimeline.Range
        var anchor: Date
    }

    var ask: Ask { Ask(asked: asked, project: project, board: board, range: range, anchor: anchor) }

    /// What the plot holds: the window, and a range's width on each side of it to scroll through.
    var content: DateInterval {
        let window = range.window(now: anchor)
        return DateInterval(start: window.start.addingTimeInterval(-range.span),
                            end: window.end.addingTimeInterval(range.span))
    }

    /// The projects the Timeline can draw: those with a folder on a machine that draws it.
    func projects(model: any WorkModel) -> [WorkList.Project] {
        let machines = Set(model.timelineMachines.map(\.id.rawValue))
        return model.workProjects.filter { project in
            project.folders.contains { machines.contains(String($0.prefix { $0 != "|" })) }
        }
    }

    func load(model: any WorkModel) async {
        let mine = ask
        guard read != mine || timeline == nil else { return }
        read = mine
        reading = true
        defer { if ask == mine { reading = false } }
        let projects = projects(model: model)
        guard let project = projects.first(where: { $0.id == self.project }) ?? projects.first else {
            timeline = .init()
            stale = false
            return
        }
        if self.project != project.id { self.project = project.id }
        let found = await model.workBoards()
        guard ask == mine else { return }
        boards = found
        let on = Set(project.folders.map { String($0.prefix { $0 != "|" }) })
        let machines = model.timelineMachines.filter { on.contains($0.id.rawValue) }
        let content = content
        let board = board
        var got: [DaemonAPI.WorkTimeline] = []
        var epics: Set<String>?
        var failed: [String] = []
        await withTaskGroup(of: (DaemonAPI.WorkTimeline?, [String]?, String?).self) { group in
            for machine in machines {
                group.addTask {
                    do {
                        let t = try await model.forge(DaemonAPI.Method.workTimeline,
                                                      DaemonAPI.WorkTimelineRequest(project: project.id, from: content.start,
                                                                                    to: content.end),
                                                      returning: DaemonAPI.WorkTimeline.self, on: machine.id)
                        // A board narrows to its epics: the forge says which they are.
                        var refs: [String]?
                        if !board.isEmpty {
                            let list = try? await model.forgeList(.issue, .init(state: "all", label: "epic", limit: 100, board: board),
                                                                  on: machine.id)
                            refs = list?.items.map(\.node.ref) ?? []
                        }
                        return (t, refs, nil)
                    } catch {
                        return (nil, nil, machines.count > 1 ? "\(machine.name): \(error.localizedDescription)" : error.localizedDescription)
                    }
                }
            }
            for await (t, refs, problem) in group {
                if let t { got.append(t) }
                if let refs { epics = (epics ?? []).union(refs) }
                if let problem { failed.append(problem) }
            }
        }
        guard ask == mine else { return }
        problem = failed.isEmpty ? nil : failed.joined(separator: "\n")
        // Every machine failed: the last plot stays, dimmed under the strip.
        stale = got.isEmpty && !failed.isEmpty && timeline != nil
        if stale { return }
        var merged = WorkTimeline.merge(got)
        if let epics { merged.epics = merged.epics.filter { epics.contains($0.item.node.ref) } }
        // A child that closed since the last read of the same window lands: its dot pulses once.
        if let before = timeline {
            let was = Set(before.epics.flatMap(\.children).filter { $0.closedAt != nil }.map(\.item.node.ref))
            let seen = Date.now
            for child in merged.epics.flatMap(\.children) where child.closedAt != nil && !was.contains(child.item.node.ref)
                && before.epics.contains(where: { $0.children.contains { $0.item.node.ref == child.item.node.ref } }) {
                landed[child.item.node.ref] = seen
            }
        }
        fromMachines = merged
        sessions = await model.lineageSessionsOn(WorkTimeline.sessionNodes(merged))?.sessions ?? []
        guard ask == mine, fromMachines == merged else { return }
        timeline = WorkTimeline.started(merged, by: sessions)
    }

    /// The sessions again, on `control/lineageChanged` (#4276): a session that starts on a child on
    /// any machine starts it, with no read of the machines' forges.
    func readSessions(model: any WorkModel) async {
        guard let machines = fromMachines, let got = await model.lineageSessionsOn(WorkTimeline.sessionNodes(machines)),
              fromMachines == machines else { return }
        sessions = got.sessions
        timeline = WorkTimeline.started(machines, by: got.sessions)
    }
}

/// Work ▸ Timeline (#4173, specs/time-stream/wireframe.md): time across, the releases line in the
/// middle, an epic's line leaving it when its first child starts and joining it when its last one
/// closes; the forecast dashed after Now. A SwiftUI `Canvas` (spike #4171): the lanes and the
/// marks come from `WorkTimeline` in AgentsKitCore.
struct WorkTimelinePane: View {
    let model: any WorkModel
    @Bindable var state: WorkTimelineState
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL

    @State private var position = ScrollPosition(edge: .leading)
    @State private var offset: Double = 0
    @State private var hover: Hover?

    struct Hover: Equatable {
        var hit: WorkTimeline.Hit
        var at: CGPoint
    }

    nonisolated static let laneHeight: Double = 60
    nonisolated static let axisHeight: Double = 26

    var body: some View {
        VStack(spacing: 0) {
            bar.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                WorkRefreshButton(running: state.reading) { state.asked += 1 }
            }
        }
        .workTask(id: state.ask) { await state.load(model: model) }
        // A machine sent new lineage to the control plane (#4276): the sessions again, no polling.
        .task(id: model.lineageChanges) {
            guard model.lineageChanges > 0 else { return }
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await state.readSessions(model: model)
        }
        // Read again every five minutes, so closes land while the page is open.
        .task(id: state.project) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                state.asked += 1
            }
        }
    }

    private var projects: [WorkList.Project] { state.projects(model: model) }

    // MARK: The bar

    /// The filter bar (parts.md section 4, milestones.md notes 31 and 32): Project and Board as
    /// compact menus and the title line at the leading edge; the range and Now at the trailing edge,
    /// where Sort is on a list. Refresh is the toolbar's. The forecast is always drawn (Alex, 2026-11-10).
    private var bar: some View {
        HStack(spacing: 14) {
            if projects.count > 1 {
                WorkFilterMenu(name: "Project", selection: $state.project, options: projects.map(\.id),
                               words: { id in projects.first { $0.id == id }?.name ?? id }, named: true)
            }
            if !state.boards.isEmpty || !state.board.isEmpty {
                WorkFilterMenu(name: "Board", selection: $state.board, options: boardOptions,
                               words: { WorkList.boardName($0, in: state.boards) }, any: "", anyWords: "All boards")
            }
            if let title {
                Text(title)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(state.timeline?.backtest.map { "The forecast after now. \(WorkTimeline.errorWords($0))." }
                        ?? "The forecast after now")
            }
            Spacer(minLength: 0)
            Picker("Range", selection: $state.range) {
                ForEach(WorkTimeline.Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: state.range) { goToNow() }
            Button("Now") { goToNow() }
                .buttonStyle(.bordered)
                .help("Back to now")
        }
    }

    /// The boards read, and the one picked when the machines no longer list it.
    private var boardOptions: [String] {
        let urls = state.boards.map(\.url)
        return state.board.isEmpty || urls.contains(state.board) ? urls : urls + [state.board]
    }

    private var projectName: String { projects.first { $0.id == state.project }?.name ?? "" }

    /// "Agents · 6 epics in these 2 days", once a read has drawn something.
    private var title: String? {
        guard let timeline = state.timeline, !projects.isEmpty else { return nil }
        let lines = WorkTimeline.lines(timeline, now: .now)
        // With the Project menu beside it, the menu names the project.
        return WorkTimeline.titleWords(project: projects.count > 1 ? "" : projectName, epics: WorkTimeline.epicCount(lines, in: state.range.window(now: state.anchor)),
                                       range: state.range)
    }

    private func goToNow() {
        state.anchor = .now
        state.nowAsked += 1
    }

    // MARK: The plot

    @ViewBuilder
    private var content: some View {
        if model.timelineMachines.isEmpty {
            WorkEmptyState(symbol: WorkList.Kind.timeline.sidebarIcon, title: "No machine draws the timeline",
                           line: WorkTimeline.noMachine)
        } else if state.timeline != nil, projects.isEmpty {
            // S12: no project to draw.
            WorkEmptyState(symbol: WorkList.Kind.timeline.sidebarIcon, title: WorkTimeline.noProject,
                           line: WorkTimeline.noProjectLine)
        } else {
            // S10: before the first read, the releases line and Now draw at once, and grey lanes shimmer.
            let timeline = state.timeline ?? .init()
            VStack(spacing: 0) {
                let lines = problems(timeline)
                if !lines.isEmpty {
                    WorkErrorStrip(lines: lines) { state.asked += 1 }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
                // Once a minute; while the first read runs, often, so the grey lanes shimmer.
                let loading = state.timeline == nil
                TimelineView(.animation(minimumInterval: loading && !reduceMotion ? 1.0 / 20 : 60)) { context in
                    plot(timeline, now: context.date, loading: loading)
                }
                .opacity(state.stale ? 0.5 : 1)
            }
        }
    }

    private func problems(_ timeline: DaemonAPI.WorkTimeline) -> [String] {
        (state.problem.map { $0.components(separatedBy: "\n") } ?? []) + (timeline.errors ?? [])
    }

    private func plot(_ timeline: DaemonAPI.WorkTimeline, now: Date, loading: Bool) -> some View {
        GeometryReader { geo in
            let visible = max(geo.size.width, 1)
            let content = state.content
            let axis = WorkTimeline.Axis(interval: content, width: visible * content.duration / state.range.span)
            // The epics and children a session is in a turn on now (#4265): their open lines pulse.
            let working = WorkTimeline.workingNow(timeline, sessions: state.sessions, agents: model.workAgents)
            let lines = WorkTimeline.layout(
                WorkTimeline.overlapping(WorkTimeline.lines(timeline, now: now, working: working), content),
                axis: axis, labelWidth: { Self.measure($0.label) })
            let lanes = WorkTimeline.lanes(lines)
            let sides = Double(max(lanes.above, lanes.below, 2))
            let height = max((2 * sides + 2) * Self.laneHeight, geo.size.height - Self.axisHeight)
            let drawing = Drawing(lines: lines, releases: timeline.releases, backtest: timeline.backtest, axis: axis,
                                  now: now, trunk: height / 2, height: height, offset: offset, visible: visible,
                                  night: scheme == .dark, project: projectName, loading: loading, moving: !reduceMotion)
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    ScrollView(.vertical) {
                        canvas(drawing, timeline: timeline)
                            .frame(width: axis.width, height: height)
                    }
                    .defaultScrollAnchor(.center, for: .initialOffset)
                    Canvas { context, _ in drawing.drawAxis(&context) }
                        .frame(width: axis.width, height: Self.axisHeight)
                        .accessibilityHidden(true)
                }
                .frame(width: axis.width, height: geo.size.height)
            }
            .scrollPosition($position)
            // Not under the sidebar: the plot is the pane's.
            .clipped()
            // The offset is under the sidebar's inset: the plot's left edge is past it.
            .onScrollGeometryChange(for: Double.self) { Double($0.contentOffset.x + $0.contentInsets.leading) } action: { _, x in
                offset = x
            }
            // A person's scroll past an edge moves the window, not the first layout's.
            .onScrollPhaseChange { old, new in
                if new == .idle, old == .interacting || old == .decelerating { shift(x: offset, visible: visible) }
            }
            // The window starts a screen in: a range's width is before it.
            .onAppear { scroll(to: visible) }
            .onChange(of: state.nowAsked) { scroll(to: visible) }
            .gesture(MagnifyGesture().onEnded { value in
                // A pinch steps the range: apart is closer in, together further out.
                if value.magnification > 1.25 || value.magnification < 0.8 {
                    state.range = state.range.zoomed(in: value.magnification > 1)
                }
            })
            .overlay {
                // S11: no line in the window itself; the margin on each side is only for the scroll.
                if !loading, WorkTimeline.overlapping(lines, state.range.window(now: state.anchor)).isEmpty {
                    emptyCard(timeline, now: now)
                }
            }
        }
    }

    /// S11: no epic in the window. The releases line and Now stay; the card says when the last one
    /// joined, when the read knows, and offers the week.
    private func emptyCard(_ timeline: DaemonAPI.WorkTimeline, now: Date) -> some View {
        let window = state.range.window(now: state.anchor)
        let joined = WorkTimeline.lastJoined(timeline, before: window.start)
        return VStack(spacing: 6) {
            Text(WorkTimeline.noEpicsWords(state.range)).appText(.supporting).fontWeight(.semibold)
            if let joined {
                Text(WorkTimeline.lastJoinedWords(joined, now: now)).appText(.fine).foregroundStyle(.secondary)
            }
            if state.range != .week {
                Button(WorkTimeline.showTheWeek) { state.range = .week }
                    .buttonStyle(.paper)
                    .padding(.top, 2)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.control).fill(Paper.raised))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.control).strokeBorder(Paper.rule))
    }

    /// A scroll the page makes: the offset is known at once, as a scroll geometry change does
    /// not come for it.
    private func scroll(to x: Double) {
        position.scrollTo(x: x)
        offset = x
    }

    /// Past an edge of what the plot holds, the window moves by a range, and the plot with it.
    private func shift(x: Double, visible: Double) {
        let total = visible * state.content.duration / state.range.span
        if x < visible * 0.05 {
            state.anchor = state.anchor.addingTimeInterval(-state.range.span)
            scroll(to: x + visible)
        } else if x > total - visible * 1.05, total > visible * 2 {
            state.anchor = state.anchor.addingTimeInterval(state.range.span)
            scroll(to: x - visible)
        }
    }

    private func canvas(_ drawing: Drawing, timeline: DaemonAPI.WorkTimeline) -> some View {
        Canvas { context, _ in drawing.draw(&context) }
            .overlay { working(drawing) }
            .overlay { pulses(drawing) }
            .overlay(alignment: .topLeading) {
                if let hover {
                    card(hover.hit, drawing: drawing)
                        .offset(x: hover.at.x + 14, y: hover.at.y + 14)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    let hit = WorkTimeline.hit((Double(p.x), Double(p.y)), lines: drawing.lines, releases: drawing.releases,
                                               axis: drawing.axis, trunk: drawing.trunk, laneHeight: Self.laneHeight)
                    hover = hit.map { Hover(hit: $0, at: p) }
                case .ended:
                    hover = nil
                }
            }
            .onTapGesture { p in
                guard let hit = WorkTimeline.hit((Double(p.x), Double(p.y)), lines: drawing.lines, releases: drawing.releases,
                                                 axis: drawing.axis, trunk: drawing.trunk, laneHeight: Self.laneHeight)
                else { return }
                open(hit)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Timeline")
            .accessibilityChildren {
                // A list in time order (section 5), each opening its epic's Plan.
                ForEach(WorkTimeline.spoken(drawing.lines, now: drawing.now), id: \.line.id) { row in
                    Button(row.words) { open(.line(row.line)) }
                }
            }
    }

    /// A dot that landed while the page is open pulses once; not with Reduce Motion.
    @ViewBuilder
    private func pulses(_ drawing: Drawing) -> some View {
        let landed = state.landed
        if !landed.isEmpty, !reduceMotion {
            TimelineView(.animation) { context in
                Canvas { gc, _ in drawing.drawPulses(&gc, landed: landed, at: context.date) }
            }
            .allowsHitTesting(false)
            .task(id: landed.count) {
                try? await Task.sleep(for: .seconds(1.2))
                let old = Date.now.addingTimeInterval(-1.1)
                state.landed = state.landed.filter { $0.value > old }
            }
        }
    }

    /// An epic a session is in a turn on now (#4265): its open line is drawn twice as thick, a glow
    /// under it breathes and its ◐ at Now turns; with Reduce Motion, the thick line and a still ◐.
    /// One clock for every working line and ring (#1653).
    @ViewBuilder
    private func working(_ drawing: Drawing) -> some View {
        if !reduceMotion, drawing.lines.contains(where: drawing.isWorking) {
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                Canvas { gc, _ in drawing.drawWorking(&gc, at: context.date) }
            }
            .allowsHitTesting(false)
        }
    }

    private func open(_ hit: WorkTimeline.Hit) {
        switch hit {
        case .dot(_, let dot):
            model.showWork(WorkPlace(kind: .issue, ref: dot.ref))
        case .line(let line):
            model.showWork(WorkPlace(kind: .issue, ref: line.epic.ref))
        case .join(let join):
            if let line = drawingLine(join.lines.first) { model.showWork(WorkPlace(kind: .issue, ref: line)) }
        case .release(let release):
            if let url = release.url.flatMap(URL.init(string:)) { openURL(url) }
        }
    }

    /// A join's epic, from a line's id (`<ref>/<segment>`).
    private func drawingLine(_ id: String?) -> String? {
        guard let id, let slash = id.lastIndex(of: "/") else { return nil }
        return String(id[..<slash])
    }

    // MARK: The hover card

    /// A mini row (milestones.md note 33) on three lines (Alex, 2026-11-10): the state glyph and the
    /// title; the label chips where the wire has them (#4428); then the prediction. A join of
    /// several lines has a row for each.
    private func card(_ hit: WorkTimeline.Hit, drawing: Drawing) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            switch hit {
            case .dot(_, let dot):
                let child = self.child(dot.ref)
                miniRow(glyph: dotGlyph(dot), title: dot.title, labels: child?.item.labels ?? [],
                        line: WorkTimeline.dotLine(dot, now: drawing.now))
            case .line(let line):
                lineRow(line, drawing: drawing)
            case .join(let join):
                ForEach(join.lines, id: \.self) { id in
                    if let line = drawing.lines.first(where: { $0.id == id }) { lineRow(line, drawing: drawing) }
                }
            case .release(let release):
                miniRow(glyph: AnyView(Image(icon: WorkList.Kind.release.sidebarIcon).foregroundStyle(.secondary)
                            .accessibilityHidden(true)),
                        title: release.tag, labels: [], line: WorkTimeline.releaseLine(release, now: drawing.now))
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Paper.Radius.control).fill(Paper.raised))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.control).strokeBorder(Paper.rule))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func lineRow(_ line: WorkTimeline.Line, drawing: Drawing) -> some View {
        let epic = state.timeline?.epics.first { $0.item.node.ref == line.epic.ref }
        let glyph = AnyView(WorkStateIcon(kind: "issue", state: epic?.item.state ?? (line.open ? "open" : "closed"),
                                          stateReason: epic?.stateReason))
        return miniRow(glyph: glyph, title: line.title, labels: epic?.item.labels ?? [],
                       line: WorkTimeline.lineLine(line, now: drawing.now))
    }

    private func miniRow(glyph: AnyView, title: String, labels: [DaemonAPI.ForgeLabel], line: String) -> some View {
        let chips = WorkLook.shownLabels(labels, limit: WorkLook.rowChips)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                glyph
                Text(title).appText(.supporting).fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
            }
            if !chips.shown.isEmpty {
                HStack(spacing: 4) {
                    ForEach(chips.shown, id: \.name) { WorkLabelChip(label: $0) }
                    WorkMoreChips(count: chips.more)
                }
                .padding(.leading, 22)
            }
            Text(line).appText(.fine).foregroundStyle(.secondary).lineLimit(1).padding(.leading, 22)
        }
    }

    /// A child's glyph: open, done, or not planned (a ring with a slash).
    private func dotGlyph(_ dot: WorkTimeline.Dot) -> AnyView {
        AnyView(WorkStateIcon(kind: "issue", state: dot.closed ? "closed" : "open", stateReason: dot.notPlanned ? "not_planned" : nil))
    }

    private func child(_ ref: String) -> DaemonAPI.WorkTimelineChild? {
        state.timeline?.epics.lazy.flatMap(\.children).first { $0.item.node.ref == ref }
    }

    /// The labels' step, as the canvas resolves it.
    nonisolated static var labelFont: NSFont { TextStep.fine.nsFont }

    /// A label's width, as the canvas draws it.
    nonisolated static func measure(_ text: String) -> Double {
        Double((text as NSString).size(withAttributes: [.font: labelFont]).width)
    }
}

/// What one frame of the plot draws, and how.
private struct Drawing {
    var lines: [WorkTimeline.Line]
    var releases: [DaemonAPI.WorkTimelineRelease]
    var backtest: DaemonAPI.WorkTimelineBacktest?
    var axis: WorkTimeline.Axis
    var now: Date
    var trunk: Double
    var height: Double
    var offset: Double
    var visible: Double
    var night: Bool
    var project: String
    /// Before the first read (S10): grey lanes that shimmer with the clock.
    var loading = false
    /// Not Reduce Motion: the working lines' ◐ turns in the overlay, on the glow's clock.
    var moving = true

    /// One breath of a working line's glow and one turn of its ◐, in seconds (#4265).
    static let pulsePeriod = 1.6

    /// The system colours for the features; the last, grey, for an epic with none.
    static let palette: [Color] = [.blue, .purple, .pink, Color.orange, Color.green, .teal, .indigo, .mint, .brown, .cyan, Color.red, .gray]
    /// Now: a grey line with its time in a grey pill (Alex, 2026-11-10).
    static let nowGrey = Color(white: 0.55)
    /// Where a line stops for the person: the colour of what waits on them.
    static let waits = StateTint.attention.color ?? .primary
    static let navy = Color(red: 0.05, green: 0.08, blue: 0.16)

    /// One background before and after Now (Alex, 2026-11-10).
    var plot: Color { night ? Self.navy : .white }
    var ink: Color { night ? Color(white: 0.85) : Color(white: 0.45) }
    var faint: Color { night ? Color(white: 0.6) : Color(white: 0.55) }

    func colour(_ line: WorkTimeline.Line) -> Color {
        let base = Self.palette[WorkTimeline.colour(line.feature, of: Self.palette.count)]
        // At night the system colours are mixed 25% with white, to keep 3:1 on the navy (section 11).
        return night ? base.mix(with: .white, by: 0.25) : base
    }

    func y(_ lane: Int) -> Double { trunk - Double(lane) * WorkTimelinePane.laneHeight }

    /// What is drawn: the window, and a screen on each side of it.
    var seen: ClosedRange<Double> { (offset - visible)...(offset + 2 * visible) }

    func draw(_ gc: inout GraphicsContext) {
        let nowX = axis.x(now)
        gc.fill(Path(CGRect(x: 0, y: 0, width: axis.width, height: height)), with: .color(plot))
        let shown = lines.filter { axis.x($0.start) <= seen.upperBound && axis.x(max($0.end, $0.band?.end ?? $0.end)) >= seen.lowerBound }

        // The bands under everything (8 times in 10).
        for line in shown {
            guard let band = line.band else { continue }
            let rect = CGRect(x: axis.x(band.start), y: y(line.lane) - 7, width: max(axis.x(band.end) - axis.x(band.start), 2), height: 14)
            gc.fill(Path(roundedRect: rect, cornerRadius: 7), with: .color(colour(line).opacity(0.13)))
        }

        // The releases line: solid to Now, dashed after, the brightest at night.
        var trunkPath = Path()
        trunkPath.move(to: CGPoint(x: 0, y: trunk))
        trunkPath.addLine(to: CGPoint(x: axis.width, y: trunk))
        stroke(&gc, trunkPath, colour: night ? .white.opacity(0.9) : Color(white: 0.6), width: 2.5, nowX: nowX, glow: night)

        // The lines.
        for line in shown {
            stroke(&gc, path(line), colour: colour(line), width: isWorking(line) ? 4 : 2, nowX: nowX, glow: night)
        }

        // The joins on the releases line.
        for join in WorkTimeline.joins(shown, axis: axis) {
            let x = axis.x(join.at)
            let colour = lines.first { $0.id == join.lines.first }.map(colour) ?? ink
            // A ring with a count is larger, so the count reads.
            let r = join.lines.count > 1 ? 9.0 : 6.0
            let ring = Path(ellipseIn: CGRect(x: x - r, y: trunk - r, width: 2 * r, height: 2 * r))
            if join.forecast {
                gc.fill(ring, with: .color(plot))
                gc.stroke(ring, with: .color(colour), style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
            } else {
                gc.fill(ring, with: .color(colour))
            }
            if join.lines.count > 1 {
                gc.draw(Text("\(join.lines.count)").stepped(.fine).fontWeight(.bold)
                    .foregroundStyle(join.forecast ? colour : .white), at: CGPoint(x: x, y: trunk))
            }
        }

        // The releases: a ring on the releases line; its tag goes on after the labels.
        for release in releases {
            let x = axis.x(release.at)
            guard seen.contains(x) else { continue }
            let ring = Path(ellipseIn: CGRect(x: x - 5, y: trunk - 5, width: 10, height: 10))
            gc.fill(ring, with: .color(plot))
            gc.stroke(ring, with: .color(night ? .white : .black), lineWidth: 2)
        }

        // The dots, and the children working now.
        for line in shown {
            let c = colour(line)
            for dot in line.dots {
                let x = WorkTimeline.dotX(dot, on: line, axis: axis)
                let r = dot.closed ? 4.0 : 3.5
                let circle = Path(ellipseIn: CGRect(x: x - r, y: y(line.lane) - r, width: 2 * r, height: 2 * r))
                if dot.closed {
                    gc.fill(circle, with: .color(dot.notPlanned ? faint : c))
                } else {
                    gc.fill(circle, with: .color(plot))
                    gc.stroke(circle, with: .color(c), lineWidth: 1.5)
                }
            }
            // With motion the ◐ turns in the overlay; with Reduce Motion it is still, here.
            if isWorking(line), !moving { drawHalfRing(&gc, line, x: nowX, turn: 0) }
            switch line.how {
            case .dropped:
                let x = axis.x(line.end), yl = y(line.lane)
                var cross = Path()
                cross.move(to: CGPoint(x: x - 4, y: yl - 4)); cross.addLine(to: CGPoint(x: x + 4, y: yl + 4))
                cross.move(to: CGPoint(x: x - 4, y: yl + 4)); cross.addLine(to: CGPoint(x: x + 4, y: yl - 4))
                gc.stroke(cross, with: .color(c), lineWidth: 2)
            default:
                break
            }
        }

        if loading { drawPlaceholders(&gc) }

        // Now: a grey line.
        var nowLine = Path()
        nowLine.move(to: CGPoint(x: nowX, y: 0))
        nowLine.addLine(to: CGPoint(x: nowX, y: height))
        gc.stroke(nowLine, with: .color(Self.nowGrey), lineWidth: 1.5)

        // Last, on a halo: the labels, the pills that wait for the person, the arrows at the edges.
        let left = offset, right = offset + visible
        var labels: [CGRect] = []
        for line in shown {
            let yl = y(line.lane)
            let c = colour(line)
            if case .waits(let n) = line.how {
                // Where the forecast stops: "3 wait for you", with a person.
                let words = Text("\(Image(icon: "person.fill")) \(WorkTimeline.waitWords(n))")
                let width = WorkTimelinePane.measure(WorkTimeline.waitWords(n)) + 16
                pill(&gc, words, at: CGPoint(x: axis.x(line.end) + 6 + width / 2, y: yl), fill: Self.waits, text: .white)
            }
            let startX = axis.x(line.start) + WorkTimeline.riser(line.lane) + 4
            let endX = axis.x(line.end)
            guard endX >= left || line.open, startX <= right else { continue }
            let cutLeft = startX < left + 8
            let x = cutLeft ? left + 8 : startX
            let room = WorkTimeline.labelRoom(line, from: x, axis: axis) - (cutLeft ? 14 : 0)
            if let words = WorkTimeline.label(line, room: room, measure: WorkTimelinePane.measure) {
                let arrow = cutLeft ? "← " : ""
                let text: Text = words.title.isEmpty
                    ? Text(arrow + words.figures).foregroundStyle(faint)
                    : Text("\(Text(arrow).foregroundStyle(faint))\(Text(words.title).foregroundStyle(c))\(Text("  " + words.figures).foregroundStyle(faint))")
                let resolved = gc.resolve(text.stepped(.fine))
                let size = resolved.measure(in: CGSize(width: room.isFinite ? room + 20 : 2000, height: 20))
                let halo = CGRect(x: x - 3, y: yl - 9 - size.height / 2 - 2, width: size.width + 6, height: size.height + 2)
                gc.fill(Path(roundedRect: halo, cornerRadius: 3), with: .color(plot.opacity(0.85)))
                labels.append(halo)
                gc.draw(resolved, at: CGPoint(x: x, y: yl - 9), anchor: .leading)
            }
            // → for a line that goes on past the right edge.
            if max(endX, line.band.map { axis.x($0.end) } ?? endX) > right, line.lane != 0 {
                gc.draw(Text("→").stepped(.fine).fontWeight(.bold).foregroundStyle(c), at: CGPoint(x: right - 10, y: yl - 9))
            }
        }

        // The releases line's name, held at the left edge.
        if !project.isEmpty {
            let name = gc.resolve(Text(project).stepped(.fine).fontWeight(.semibold).foregroundStyle(faint))
            let size = name.measure(in: CGSize(width: 400, height: 20))
            gc.draw(name, at: CGPoint(x: left + 8, y: trunk - 6), anchor: .bottomLeading)
            labels.append(CGRect(x: left + 8, y: trunk - 6 - size.height, width: size.width, height: size.height))
        }

        // The release tags: below the releases line, unless a label is there and none is above
        // (section 12, item 6).
        for release in releases {
            let x = axis.x(release.at)
            guard seen.contains(x) else { continue }
            let width = WorkTimelinePane.measure(release.tag) + 12
            func free(_ y: Double) -> Bool {
                !labels.contains { $0.intersects(CGRect(x: x - width / 2, y: y - 9, width: width, height: 18)) }
            }
            // With a label on each side, the ring alone: its hover card says the tag.
            guard free(trunk + 17) || free(trunk - 17) else { continue }
            let below = free(trunk + 17)
            pill(&gc, release.tag, at: CGPoint(x: x, y: trunk + (below ? 17 : -17)),
                 fill: night ? .white : .black, text: night ? .black : .white)
        }

    }

    /// S10: a grey bar on each of the first lanes, in the window, its grey breathing with the clock.
    func drawPlaceholders(_ gc: inout GraphicsContext) {
        let phase = 0.5 + 0.5 * sin(now.timeIntervalSinceReferenceDate * .pi / 1.1)
        let grey = Paper.wash.opacity(0.55 + 0.45 * phase)
        for (lane, from, width) in [(1, 0.12, 0.42), (-1, 0.28, 0.36), (2, 0.36, 0.3), (-2, 0.08, 0.26)] {
            let rect = CGRect(x: offset + visible * from, y: y(lane) - 4, width: visible * width, height: 8)
            gc.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(grey))
        }
    }

    /// A line's path: a cubic curve up from the releases line, along its lane, and a curve back
    /// down when it joins (section 10). The rise is in points, not minutes (section 12, item 2).
    func path(_ line: WorkTimeline.Line) -> Path {
        let r = WorkTimeline.riser(line.lane)
        let sx = axis.x(line.start), ex = max(axis.x(line.end), sx)
        let yl = y(line.lane)
        let joins = line.how == .joined || line.how == .forecast
        var p = Path()
        p.move(to: CGPoint(x: sx, y: trunk))
        p.addCurve(to: CGPoint(x: sx + r, y: yl), control1: CGPoint(x: sx + r / 2, y: trunk), control2: CGPoint(x: sx + r / 2, y: yl))
        if joins {
            let jx = max(ex - r, sx + r)
            p.addLine(to: CGPoint(x: jx, y: yl))
            p.addCurve(to: CGPoint(x: jx + r, y: trunk), control1: CGPoint(x: jx + r / 2, y: yl), control2: CGPoint(x: jx + r / 2, y: trunk))
        } else {
            p.addLine(to: CGPoint(x: max(ex, sx + r), y: yl))
        }
        return p
    }

    /// Solid up to Now and dashed after it; at night with a soft blur under it.
    func stroke(_ gc: inout GraphicsContext, _ path: Path, colour: Color, width: Double, nowX: Double, glow: Bool) {
        if glow {
            gc.drawLayer { layer in
                layer.addFilter(.blur(radius: 3))
                layer.stroke(path, with: .color(colour.opacity(0.7)), lineWidth: width + 2)
            }
        }
        gc.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: -100, y: 0, width: nowX + 100, height: height)))
            layer.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        gc.drawLayer { layer in
            layer.clip(to: Path(CGRect(x: nowX, y: 0, width: axis.width - nowX + 100, height: height)))
            layer.stroke(path, with: .color(colour), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [5, 4]))
        }
    }

    func pill(_ gc: inout GraphicsContext, _ words: String, at: CGPoint, fill: Color, text: Color) {
        pill(&gc, Text(words), at: at, fill: fill, text: text)
    }

    func pill(_ gc: inout GraphicsContext, _ words: Text, at: CGPoint, fill: Color, text: Color) {
        let resolved = gc.resolve(words.stepped(.fine).fontWeight(.semibold).foregroundStyle(text))
        let size = resolved.measure(in: CGSize(width: 400, height: 20))
        let rect = CGRect(x: at.x - size.width / 2 - 6, y: at.y - size.height / 2 - 2, width: size.width + 12, height: size.height + 4)
        gc.fill(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(fill))
        gc.draw(resolved, at: at)
    }

    /// The hour axis at the foot, and Now's time in a grey pill.
    func drawAxis(_ gc: inout GraphicsContext) {
        gc.fill(Path(CGRect(x: 0, y: 0, width: axis.width, height: WorkTimelinePane.axisHeight)), with: .color(plot))
        let calendar = Calendar.current
        let nowX = axis.x(now)
        for tick in axis.ticks(seen: visible * axis.interval.duration / max(axis.width, 1)) {
            let x = axis.x(tick)
            // Now's pill is where the tick under it would be.
            guard seen.contains(x), abs(x - nowX) > 44 else { continue }
            let midnight = calendar.component(.hour, from: tick) == 0
            let words = midnight ? tick.formatted(.dateTime.weekday(.abbreviated).day()) : tick.formatted(.dateTime.hour())
            var mark = Path()
            mark.move(to: CGPoint(x: x, y: 0))
            mark.addLine(to: CGPoint(x: x, y: midnight ? 7 : 4))
            gc.stroke(mark, with: .color(faint), lineWidth: 1)
            gc.draw(Text(words).stepped(.fine).fontWeight(midnight ? .semibold : .regular).foregroundStyle(faint),
                    at: CGPoint(x: x, y: 15))
        }
        pill(&gc, now.formatted(date: .omitted, time: .shortened), at: CGPoint(x: axis.x(now), y: 13), fill: Self.nowGrey, text: .white)
    }

    /// A child of the line is worked on now, and the line is open at Now.
    func isWorking(_ line: WorkTimeline.Line) -> Bool {
        line.working > 0 && line.start <= now && line.end >= now
    }

    /// ◐: a ring at Now, half of it filled; `turn` of a full turn on from the left half, clockwise.
    func drawHalfRing(_ gc: inout GraphicsContext, _ line: WorkTimeline.Line, x: Double, turn: Double) {
        let c = colour(line)
        let rect = CGRect(x: x - 5, y: y(line.lane) - 5, width: 10, height: 10)
        gc.fill(Path(ellipseIn: rect), with: .color(plot))
        var half = Path()
        let from = 90 + 360 * turn
        half.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: 5, startAngle: .degrees(from),
                    endAngle: .degrees(from + 180), clockwise: false)
        gc.fill(half, with: .color(c))
        gc.stroke(Path(ellipseIn: rect), with: .color(c), lineWidth: 1.5)
    }

    /// The working lines' glow, wider than the line and breathing, and their ◐ turning: one breath
    /// and one turn in `pulsePeriod`, read off the wall clock (`SpinnerClock`), so all are in step.
    func drawWorking(_ gc: inout GraphicsContext, at time: Date) {
        let turn = SpinnerClock.fraction(at: time, period: Self.pulsePeriod)
        let phase = 0.5 - 0.5 * cos(2 * .pi * turn)
        let nowX = axis.x(now)
        for line in lines where isWorking(line) && axis.x(line.start) <= seen.upperBound && axis.x(line.end) >= seen.lowerBound {
            gc.stroke(path(line), with: .color(colour(line).opacity(0.1 + 0.3 * phase)),
                      style: StrokeStyle(lineWidth: 4 + 8 * phase, lineCap: .round))
            drawHalfRing(&gc, line, x: nowX, turn: turn)
        }
    }

    /// The dots that landed: a ring that grows and fades over a second.
    func drawPulses(_ gc: inout GraphicsContext, landed: [String: Date], at time: Date) {
        for line in lines {
            for dot in line.dots {
                guard let seen = landed[dot.ref] else { continue }
                let t = time.timeIntervalSince(seen)
                guard t >= 0, t < 1 else { continue }
                let r = 4 + 10 * t
                let x = WorkTimeline.dotX(dot, on: line, axis: axis)
                let ring = Path(ellipseIn: CGRect(x: x - r, y: y(line.lane) - r, width: 2 * r, height: 2 * r))
                gc.stroke(ring, with: .color(colour(line).opacity(1 - t)), lineWidth: 2)
            }
        }
    }
}
#endif
