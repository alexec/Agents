import AgentsKitCore
import SwiftUI

/// One Dashboard tile (074), as the Mac and the Remote both draw it: a card on paper with
/// its title, its value by type, and a foot naming its keeper and its age. A stale tile
/// is greyed, and a stale status shows no colour (FR-024).
struct TileCard: View {
    let tile: TileView
    let now: Date
    /// The phone's: tables to their first five rows.
    var rowLimit: Int?
    /// Picking the keeper opens its session or workflow (FR-030).
    var openKeeper: (() -> Void)?
    /// Picking a link tile, or a table cell with a link.
    var openLink: ((TileLink) -> Void)?
    /// A page tile's page, drawn live by the app the card is in (#159): the Mac and the
    /// phone read the project's files differently.
    var page: ((TilePage) -> AnyView)?

    private var isStale: Bool { DashboardModel.isStale(tile, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(tile.tile?.title ?? tile.id)
                    .appText(.fine).fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if tile.tile?.isHidden == true {
                    Image(systemName: "eye.slash").appText(.fine).foregroundStyle(.tertiary)
                        .accessibilityLabel("Hidden")
                }
                Spacer(minLength: 0)
            }
            value
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            foot
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Paper.raised, in: .rect(cornerRadius: Paper.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
        .saturation(isStale ? 0 : 1)
        .opacity(isStale ? 0.55 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(tile.tile?.title ?? tile.id)
    }

    // MARK: The value, by type

    @ViewBuilder
    private var value: some View {
        if let file = tile.tile {
            switch file.type {
            case .number: number(file)
            case .status: status(file)
            case .table: table(file)
            case .note: note(file)
            case .link: link(file)
            case .page:
                if let shown = file.page, let page {
                    page(shown)
                } else {
                    Label(file.page?.file ?? "", systemImage: "doc.text")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            Label(tile.problem ?? "This tile's file can't be read.", systemImage: "exclamationmark.triangle")
                .appText(.supporting)
                .foregroundStyle(StateTint.failure.style(or: .secondary))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func number(_ file: TileFile) -> some View {
        let number = file.number ?? TileNumber(value: 0)
        let change = DashboardModel.change(tile, now: now)
        let good = change.flatMap { DashboardModel.isGood(change: $0, good: number.good) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(DashboardModel.numberWords(number.value))
                    .appText(.title).fontWeight(.semibold)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if let unit = number.unit, !unit.isEmpty {
                    Text(unit).appText(.supporting).foregroundStyle(.secondary)
                }
                if let words = DashboardModel.changeWords(change) {
                    Text(words)
                        .appText(.fine).monospacedDigit()
                        .foregroundStyle((isStale ? StateTint.none
                                          : good == true ? .vouched : good == false ? .failure : .none)
                            .style(or: .secondary))
                }
            }
            if tile.points.count > 1 {
                Sparkline(points: tile.points)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(height: 26)
                    .accessibilityHidden(true)
            }
        }
    }

    private func status(_ file: TileFile) -> some View {
        let level = DashboardModel.shownLevel(tile, now: now) ?? .unknown
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(Self.tint(level).style(or: Color.secondary.opacity(0.4)))
                .frame(width: 10, height: 10)
                .accessibilityLabel(level.rawValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.status?.line ?? "")
                    .appText(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
                if let since = file.status?.since {
                    Text("since \(since)").appText(.fine).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func table(_ file: TileFile) -> some View {
        let table = file.table ?? TileTable(columns: [], rows: [])
        let rows = rowLimit.map { Array(table.rows.prefix($0)) } ?? table.rows
        return VStack(alignment: .leading, spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow {
                    ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                        Text(column).appText(.fine).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            cellView(cell)
                        }
                    }
                }
            }
            if rows.count < table.rows.count {
                Text("All \(table.rows.count) rows").appText(.fine).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: TileCell) -> some View {
        if let url = cell.url, let openLink {
            Button(cell.text) { openLink(TileLink(url: url)) }
                .buttonStyle(.plain).foregroundStyle(.tint)
                .appText(.supporting)
                .lineLimit(2)
        } else {
            Text(cell.text).appText(.supporting).lineLimit(2)
        }
    }

    private func note(_ file: TileFile) -> some View {
        let markdown = file.note?.markdown ?? ""
        let text = (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown)
        return Text(text)
            .appText(.supporting)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func link(_ file: TileFile) -> some View {
        let target = file.link ?? TileLink()
        let words = target.url.flatMap { URL(string: $0)?.host() } ?? target.file
            ?? (target.session != nil ? "A session" : target.workflow.map { "Workflow \($0)" }) ?? ""
        return Button {
            openLink?(target)
        } label: {
            HStack(spacing: 4) {
                Text(words).lineLimit(1)
                Image(systemName: target.url != nil ? "arrow.up.right" : "arrow.right")
            }
        }
        .buttonStyle(.plain).foregroundStyle(.tint)
        .appText(.supporting)
    }

    // MARK: The foot

    private var foot: some View {
        HStack(spacing: 4) {
            if let openKeeper {
                Button(tile.keeper.name, action: openKeeper)
                    .buttonStyle(.plain)
                    .underline(false)
                    .help("Open the \(tile.keeper.kind == .workflow ? "workflow" : "session") that keeps this tile")
            } else {
                Text(tile.keeper.name)
            }
            Text("·")
            Text(DashboardModel.ageWords(tile, now: now))
            if let note = DashboardModel.keeperNote(tile.keeper) {
                Text("·")
                Text(note)
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    /// Green for ok, orange for warn, red for bad, and no colour for unknown or stale.
    static func tint(_ level: TileLevel) -> StateTint {
        switch level {
        case .ok: .vouched
        case .warn: .attention
        case .bad: .failure
        case .unknown: .none
        }
    }

    /// Whether this tile takes the whole width of the grid: tables and notes do.
    static func isWide(_ tile: TileView) -> Bool {
        guard let type = tile.tile?.type else { return false }
        return type == .table || type == .note || type == .page
    }
}

/// A number tile's trend: one line through its points, scaled to fit.
struct Sparkline: Shape {
    let points: [TilePoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 1, let first = points.first, let last = points.last else { return path }
        let values = points.map(\.value)
        let low = values.min() ?? 0, high = values.max() ?? 0
        let span = max(high - low, 1e-9)
        let start = first.at.timeIntervalSince1970
        let width = max(last.at.timeIntervalSince1970 - start, 1)
        for (index, point) in points.enumerated() {
            let x = rect.minX + rect.width * (point.at.timeIntervalSince1970 - start) / width
            let y = high == low ? rect.midY : rect.maxY - rect.height * (point.value - low) / span
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}
