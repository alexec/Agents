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
    var forecast = true
    /// The project, by id; "" until one is picked, then the first one.
    var project = ""
    /// The board the epics are narrowed to (#3282), by its url; "" for every board.
    var board = ""
    var boards: [DaemonAPI.ProjectBoard] = []
    /// Where the window is: Now, until the plot is scrolled past an edge.
    var anchor = Date.now
    var timeline: DaemonAPI.WorkTimeline?
    var problem: String?
    var asked = 0
    /// Now was clicked: the plot scrolls back to it.
    var nowAsked = 0
    /// Children that closed since the last read, and when they were seen: their dots pulse once.
    var landed: [String: Date] = [:]
    private var read: Ask?

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
        let projects = projects(model: model)
        guard let project = projects.first(where: { $0.id == self.project }) ?? projects.first else {
            timeline = .init()
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
        problem = failed.isEmpty ? nil : failed.joined(separator: "\n")
        timeline = merged
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

    nonisolated static let laneHeight: Double = 30
    nonisolated static let axisHeight: Double = 26

    var body: some View {
        VStack(spacing: 0) {
            bar.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .workTask(id: state.ask) { await state.load(model: model) }
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

    private var bar: some View {
        HStack(spacing: 12) {
            Picker("Range", selection: $state.range) {
                ForEach(WorkTimeline.Range.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .onChange(of: state.range) { goToNow() }
            Button("Now") { goToNow() }
                .help("Back to now")
            Toggle("Forecast", isOn: $state.forecast)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help(state.timeline?.backtest.map { "The forecast after now. \(WorkTimeline.errorWords($0))." }
                    ?? "The forecast after now")
            if projects.count > 1 {
                Picker("Project", selection: $state.project) {
                    ForEach(projects) { Text($0.name).tag($0.id) }
                }
                .fixedSize()
            }
            if !state.boards.isEmpty || !state.board.isEmpty {
                WorkBoardPicker(selection: $state.board, boards: state.boards)
            }
            Spacer(minLength: 0)
            Button("Refresh") { state.asked += 1 }
                .linkStyle()
                .fixedSize()
        }
    }

    private func goToNow() {
        state.anchor = .now
        state.nowAsked += 1
    }

    // MARK: The plot

    @ViewBuilder
    private var content: some View {
        if model.timelineMachines.isEmpty {
            message(WorkTimeline.noMachine)
        } else if let timeline = state.timeline {
            if projects.isEmpty {
                message(WorkTimeline.noProject)
            } else {
                VStack(spacing: 0) {
                    ForEach(problems(timeline), id: \.self) { line in
                        Label(line, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 4)
                    }
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        plot(timeline, now: context.date)
                    }
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func problems(_ timeline: DaemonAPI.WorkTimeline) -> [String] {
        [state.problem].compactMap { $0 } + (timeline.errors ?? [])
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func plot(_ timeline: DaemonAPI.WorkTimeline, now: Date) -> some View {
        GeometryReader { geo in
            let visible = max(geo.size.width, 1)
            let content = state.content
            let axis = WorkTimeline.Axis(interval: content, width: visible * content.duration / state.range.span)
            let lines = WorkTimeline.layout(
                WorkTimeline.overlapping(WorkTimeline.lines(timeline, now: now, forecast: state.forecast), content),
                axis: axis, labelWidth: { Self.measure($0.label) })
            let lanes = WorkTimeline.lanes(lines)
            let sides = Double(max(lanes.above, lanes.below, 2))
            let height = max((2 * sides + 2) * Self.laneHeight, geo.size.height - Self.axisHeight)
            let drawing = Drawing(lines: lines, releases: timeline.releases, backtest: timeline.backtest, axis: axis,
                                  now: now, trunk: height / 2, height: height, offset: offset, visible: visible,
                                  night: scheme == .dark, project: projects.first { $0.id == state.project }?.name ?? "")
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
                if lines.isEmpty {
                    Text(WorkTimeline.noEpics)
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .allowsHitTesting(false)
                }
            }
        }
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

    private func card(_ hit: WorkTimeline.Hit, drawing: Drawing) -> some View {
        let lines: [String] = switch hit {
        case .dot(_, let dot): WorkTimeline.dotWords(dot, now: drawing.now)
        case .line(let line): WorkTimeline.lineWords(line, backtest: drawing.backtest, now: drawing.now)
        case .join(let join):
            join.lines.flatMap { id -> [String] in
                guard let line = drawing.lines.first(where: { $0.id == id }) else { return [] }
                return line.how == .forecast
                    ? ["\(line.number) \(line.title)"] + WorkTimeline.joinWords(line, backtest: drawing.backtest, now: drawing.now)
                    : WorkTimeline.lineWords(line, backtest: drawing.backtest, now: drawing.now)
            }
        case .release(let release):
            [release.tag, "Released \(release.at.formatted(date: .abbreviated, time: .shortened))"]
        }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .appText(i == 0 ? .supporting : .fine)
                    .fontWeight(i == 0 ? .semibold : .regular)
                    .foregroundStyle(i == 0 ? .primary : .secondary)
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        .fixedSize(horizontal: false, vertical: true)
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

    /// The system colours for the features; the last, grey, for an epic with none.
    static let palette: [Color] = [.blue, .purple, .pink, Color.orange, Color.green, .teal, .indigo, .mint, .brown, .cyan, Color.red, .gray]
    /// Now: a red line with its time in a red pill, as in Calendar.
    static let nowRed = Color.red
    /// Where a line stops for the person: the colour of what waits on them.
    static let waits = StateTint.attention.color ?? .primary
    static let navy = Color(red: 0.05, green: 0.08, blue: 0.16)
    static let navyAhead = Color(red: 0.08, green: 0.12, blue: 0.22)

    var plot: Color { night ? Self.navy : .white }
    var ahead: Color { night ? Self.navyAhead : Color(white: 0.965) }
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
        gc.fill(Path(CGRect(x: nowX, y: 0, width: max(axis.width - nowX, 0), height: height)), with: .color(ahead))
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
            stroke(&gc, path(line), colour: colour(line), width: 2, nowX: nowX, glow: night)
        }

        // The joins on the releases line.
        for join in WorkTimeline.joins(shown, axis: axis) {
            let x = axis.x(join.at)
            let colour = lines.first { $0.id == join.lines.first }.map(colour) ?? ink
            // A ring with a count is larger, so the count reads.
            let r = join.lines.count > 1 ? 9.0 : 6.0
            let ring = Path(ellipseIn: CGRect(x: x - r, y: trunk - r, width: 2 * r, height: 2 * r))
            if join.forecast {
                gc.fill(ring, with: .color(ahead))
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
                let x = axis.x(dot.at)
                let r = dot.closed ? 4.0 : 3.5
                let circle = Path(ellipseIn: CGRect(x: x - r, y: y(line.lane) - r, width: 2 * r, height: 2 * r))
                if dot.closed {
                    gc.fill(circle, with: .color(dot.notPlanned ? faint : c))
                } else {
                    gc.fill(circle, with: .color(ahead))
                    gc.stroke(circle, with: .color(c), lineWidth: 1.5)
                }
            }
            if line.working > 0, line.start <= now, line.end >= now {
                // ◐: a ring at Now, its left half filled.
                let rect = CGRect(x: nowX - 5, y: y(line.lane) - 5, width: 10, height: 10)
                gc.fill(Path(ellipseIn: rect), with: .color(plot))
                var half = Path()
                half.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: 5, startAngle: .degrees(90),
                            endAngle: .degrees(270), clockwise: false)
                gc.fill(half, with: .color(c))
                gc.stroke(Path(ellipseIn: rect), with: .color(c), lineWidth: 1.5)
            }
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

        // Now: a red line.
        var nowLine = Path()
        nowLine.move(to: CGPoint(x: nowX, y: 0))
        nowLine.addLine(to: CGPoint(x: nowX, y: height))
        gc.stroke(nowLine, with: .color(Self.nowRed), lineWidth: 1.5)

        // Last, on a halo: the labels, the pills that wait for the person, the arrows at the edges.
        let left = offset, right = offset + visible
        var labels: [CGRect] = []
        for line in shown {
            let yl = y(line.lane)
            let c = colour(line)
            if case .waits(let n) = line.how {
                // Where the forecast stops: "3 wait for you", with a person.
                let words = Text("\(Image(systemName: "person.fill")) \(WorkTimeline.waitWords(n))")
                let width = WorkTimelinePane.measure(WorkTimeline.waitWords(n)) + 16
                pill(&gc, words, at: CGPoint(x: axis.x(line.end) + 6 + width / 2, y: yl), fill: Self.waits, text: .white)
            }
            let startX = axis.x(line.start) + WorkTimeline.riser(line.lane) + 4
            let endX = axis.x(line.end)
            guard endX >= left || line.open, startX <= right else { continue }
            let cutLeft = startX < left + 8
            let x = cutLeft ? left + 8 : startX
            let room = WorkTimeline.labelRoom(line, from: x, axis: axis, now: now) - (cutLeft ? 14 : 0)
            if let words = WorkTimeline.label(line, room: room, measure: WorkTimelinePane.measure) {
                let arrow = cutLeft ? "← " : ""
                let text: Text = words == line.label
                    ? Text("\(Text(arrow).foregroundStyle(faint))\(Text(line.title).foregroundStyle(c))\(Text("  " + line.figures).foregroundStyle(faint))")
                    : Text(arrow + words).foregroundStyle(faint)
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

    /// The hour axis at the foot, and Now's time in a red pill, as in Calendar.
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
        pill(&gc, now.formatted(date: .omitted, time: .shortened), at: CGPoint(x: axis.x(now), y: 13), fill: Self.nowRed, text: .white)
    }

    /// The dots that landed: a ring that grows and fades over a second.
    func drawPulses(_ gc: inout GraphicsContext, landed: [String: Date], at time: Date) {
        for line in lines {
            for dot in line.dots {
                guard let seen = landed[dot.ref] else { continue }
                let t = time.timeIntervalSince(seen)
                guard t >= 0, t < 1 else { continue }
                let r = 4 + 10 * t
                let ring = Path(ellipseIn: CGRect(x: axis.x(dot.at) - r, y: y(line.lane) - r, width: 2 * r, height: 2 * r))
                gc.stroke(ring, with: .color(colour(line).opacity(1 - t)), lineWidth: 2)
            }
        }
    }
}
#endif
