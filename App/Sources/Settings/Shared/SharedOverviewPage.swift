import AgentsKit
import SwiftUI

/// Frame A: what every agent gets, in one grid of kinds by runtimes, and under it every
/// exception, each opening its own page.
struct SharedOverviewPage: View {
    let snapshot: DaemonAPI.SharedSnapshot
    @Binding var page: SharedPage

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SharedPageHeader(title: "Shared by every agent", path: snapshot.home) {
                    Button("Reveal in Finder") { SharedFiles.reveal(snapshot.home) }.buttonStyle(.paper)
                }
                grid
                legend
                if !snapshot.needsALook.isEmpty {
                    SharedSectionLabel("Needs a look")
                    ForEach(snapshot.needsALook) { look in
                        LookRow(look: look) { page = SharedPage(look.page) }
                    }
                }
            }
            .padding(20)
        }
    }

    // MARK: The grid

    private var grid: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                Text("")
                ForEach(snapshot.runtimes) { runtime in
                    Text(runtime.name).appText(.fine).fontWeight(.semibold).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8)
            Divider()
            row("Instructions", count: nil) { instructionsCell($0) }
            Divider()
            row("Skills", count: snapshot.skills.count) { countCell(snapshot.skills.map(\.reach), runtime: $0) }
            Divider()
            row("MCP servers", count: snapshot.mcp.problem == nil ? snapshot.mcp.servers.count : nil) { runtime in
                if snapshot.mcp.problem != nil {
                    Cell(text: "⚠", tone: .attention)
                } else {
                    countCell(snapshot.mcp.servers.map(\.reach), runtime: runtime)
                }
            }
            Divider()
            row("Plugins", count: snapshot.plugins.count) { countCell(snapshot.plugins.map(\.reach), runtime: $0) }
        }
        .background(Paper.raised, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Paper.rule, lineWidth: 1))
    }

    private func row(_ title: String, count: Int?, cell: @escaping (String) -> Cell) -> some View {
        GridRow {
            // A grid row is not a view of its own, so the row's one label sits on its
            // title and the cells are hidden: otherwise every cell carries it.
            HStack(spacing: 6) {
                Text(title)
                if let count { SharedChip(text: "\(count)") }
            }
            .frame(minWidth: 170, alignment: .leading)
            .padding(.leading, 14)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(spokenRow(title, cell: cell))
            ForEach(snapshot.runtimes) { runtime in
                cell(runtime.id).frame(maxWidth: .infinity).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 10)
    }

    private func spokenRow(_ title: String, cell: (String) -> Cell) -> String {
        let parts = snapshot.runtimes.map { "\($0.name) \(cell($0.id).spoken)" }
        return "\(title): " + parts.joined(separator: ", ")
    }

    private func instructionsCell(_ runtime: String) -> Cell {
        guard snapshot.instructions?.exists == true else { return Cell(text: "—", tone: .none) }
        switch snapshot.instructions?.reach[runtime] {
        case .gets: return Cell(text: "✓", tone: .gets)
        case .ownCopy: return Cell(text: "its own", tone: .attention)
        case .leftOut: return Cell(text: "left out", tone: .attention)
        case .noWay, nil: return Cell(text: "—", tone: .none)
        case .unchecked: return Cell(text: "?", tone: .none)
        }
    }

    /// `n` when every one reaches it, `n of m` when some are left out, `n · k its own`
    /// when it keeps its own copy of some, `—` when it has no way in, `?` unchecked.
    private func countCell(_ reaches: [[String: DaemonAPI.Reach]], runtime: String) -> Cell {
        guard !reaches.isEmpty else { return Cell(text: "—", tone: .none) }
        let states = reaches.compactMap { $0[runtime] }
        if states.allSatisfy({ if case .unchecked = $0 { true } else { false } }) { return Cell(text: "?", tone: .none) }
        if states.allSatisfy({ if case .noWay = $0 { true } else { false } }) { return Cell(text: "—", tone: .none) }
        let gets = states.filter(\.gets).count
        let own = states.filter { if case .ownCopy = $0 { true } else { false } }.count
        if gets == reaches.count { return Cell(text: "\(gets)", tone: .gets) }
        if own > 0 && gets + own == reaches.count { return Cell(text: "\(gets + own) · \(own) its own", tone: .attention) }
        return Cell(text: "\(gets) of \(reaches.count)", tone: .attention)
    }

    private var legend: some View {
        HStack(spacing: 18) {
            Text("\(Text("✓ / n").foregroundStyle(SharedInk.reach)) gets it")
            Text("\(Text("2 of 3").foregroundStyle(SharedInk.attention)) some left out, see why")
            Text("— has no way to take it")
            Text("? not checked yet")
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
    }

    struct Cell {
        enum Tone { case gets, attention, none }

        let text: String
        let tone: Tone

        var spoken: String {
            switch text {
            case "✓": "gets it"
            case "—": "has no way to take it"
            case "?": "not checked yet"
            case "⚠": "mcp.json can't be read"
            default: text
            }
        }
    }
}

extension SharedOverviewPage.Cell: View {
    var body: some View {
        Text(text)
            .fontWeight(tone == .gets ? .semibold : .regular)
            .foregroundStyle(tone == .gets ? SharedInk.reach : tone == .attention ? SharedInk.attention : .secondary)
            .monospacedDigit()
    }
}

/// A Needs a look row: what kind, what about, why, and the whole row opens its page.
private struct LookRow: View {
    let look: DaemonAPI.Look
    let show: () -> Void

    var body: some View {
        SharedRow(chosen: false, label: "\(tag): \(look.item). \(look.text) Show.", action: show) {
            HStack(spacing: 10) {
                SharedChip(text: tag, tone: look.kind == .noWay || look.kind == .noFile ? .plain : .attention)
                Text(look.item).fontWeight(.semibold).lineLimit(1).fixedSize()
                Text(look.text).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                Text("Show").padding(.horizontal, 12).padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(Paper.rule, lineWidth: 1))
            }
        }
    }

    private var tag: String {
        switch look.kind {
        case .clash: "clash"
        case .leftOut: "left out"
        case .noWay: "no way in"
        case .noFile: "no file"
        case .problem: "can't read"
        }
    }
}
