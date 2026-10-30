import AgentsKitCore
import SwiftUI

/// What the transcript knows of its own geometry (#2310): every row's height, measured once
/// it was drawn or estimated until then, where each row was last placed, and how the pane is
/// held. A class, read and written as the rows are laid out, so knowing it draws nothing again.
/// Not isolated, as a layout's own methods are not; only the main thread lays out and reads it.
final class TranscriptGeometry: @unchecked Sendable {
    /// Every row in order, as last laid out.
    private(set) var ids: [UUID] = []
    /// Where each row starts, as last laid out, in the order of `ids`.
    private(set) var tops: [Double] = []
    /// How tall each row is, in the order of `ids`.
    private(set) var heights: [Double] = []
    /// The content's height, as last laid out.
    private(set) var height: Double = 0
    /// Rows measured at `width`, by id. A row never drawn takes `estimate`.
    private var measured: [UUID: Double] = [:]
    private var width: Double = 0
    /// The empty space above the first row, which takes a change above the reader.
    var slack: Double = 0
    /// The row a reader's place is held by, and where it starts: nil while following the end.
    var anchor: (id: UUID, top: Double)?
    /// How far the content moved down, all at once, because the slack ran out: the pane
    /// moves by as much (`TranscriptPlacement.Placed.shift`). Taken by the transcript.
    var shift: Double = 0

    /// What a row never drawn is taken to be: the mean of those drawn, or a guess.
    var estimate: Double {
        measured.isEmpty ? 160 : measured.values.reduce(0, +) / Double(measured.count)
    }

    /// The slack a conversation opens with, so earlier pages land without moving the pane:
    /// enough for many. It costs nothing: the pane is kept out of it by a margin, so neither
    /// the reader nor the scroller sees it.
    static let reserve: Double = 500_000

    /// A row's height at `width`, measured in this layout pass.
    func measure(_ id: UUID, _ height: Double, width: Double) {
        if abs(width - self.width) > 0.5 {
            // Another width: every height measured is wrong, though nothing above the
            // reader moves while the anchor holds.
            measured = [:]
            self.width = width
        }
        measured[id] = height
    }

    /// Lays every row out: the drawn ones measured, the rest as known. Bounded: heights are
    /// kept for the rows the transcript has, not for every row it ever had.
    func place(_ ids: [UUID]) -> TranscriptPlacement.Placed {
        if self.ids != ids {
            let now = Set(ids)
            if measured.count > ids.count * 2 { measured = measured.filter { now.contains($0.key) } }
            // The anchor's row gone (a page joined onto it): the next one still here.
            if let held = anchor, !now.contains(held.id),
               let at = self.ids.firstIndex(of: held.id),
               let next = self.ids[at...].first(where: now.contains),
               let top = self.ids.firstIndex(of: next).map({ tops[$0] }) {
                anchor = (next, top)
            }
        }
        let guess = estimate
        let heights = ids.map { measured[$0] ?? guess }
        let index = anchor.flatMap { held in ids.firstIndex(of: held.id).map { ($0, held.top) } }
        let placed = TranscriptPlacement.place(heights: heights, slack: slack,
                                               anchor: index.map { (index: $0.0, top: $0.1) },
                                               reserve: Self.reserve)
        self.ids = ids
        self.heights = heights
        tops = placed.tops
        height = placed.height
        slack = placed.slack
        if placed.shift > 0, let held = anchor {
            anchor = (held.id, held.top + placed.shift)
            shift += placed.shift
        }
        return placed
    }

    /// Where a row starts, as last laid out.
    func top(of id: UUID) -> Double? { ids.firstIndex(of: id).map { tops[$0] } }

    /// Holds the reader's place by the row at the top of `from..<to`: nothing moves, as the
    /// row is where it was laid out.
    func hold(from: Double, to: Double) {
        guard let at = TranscriptPlacement.anchor(tops: tops, heights: heights, visibleTop: from, visibleBottom: to)
        else { return }
        anchor = (ids[at.index], at.top)
    }

    /// Following the end again: the rows go down from where the first one is now.
    func follow() {
        anchor = nil
    }

    /// Opened afresh: nothing measured, nothing held.
    func reset(slack: Double) {
        ids = []
        tops = []
        heights = []
        height = 0
        measured = [:]
        anchor = nil
        shift = 0
        self.slack = slack
    }
}

/// The id a row of the transcript is laid out by.
struct TranscriptRowID: LayoutValueKey {
    static let defaultValue: UUID? = nil
}

/// The transcript's rows, laid out by their own measured heights (#2310). Only the rows
/// drawn are its subviews; the others are known by their heights. Each drawn row is
/// measured in the same pass that places it, so a row that changed height moves the rows
/// around it in that pass, and the slack above takes it before anything is drawn.
struct TranscriptStack: Layout {
    /// Every row, top first, drawn or not.
    let ids: [UUID]
    /// The rows' own places, as the geometry has them: a line in a turn says where it is in
    /// these (#2860).
    static let space = "transcriptRows"
    let geometry: TranscriptGeometry
    /// Changed to lay the rows out again when what holds them changed outside a pass.
    var pass = 0

    /// The width the drawn rows were last measured at, in this layout of them: the pass that
    /// sizes the stack measures them, and the one that places them uses what it measured
    /// (P20261022-18). Nil once the rows or the stack change.
    struct Cache {
        var measuredWidth: Double?
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.measuredWidth = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        measure(subviews, width: width)
        cache.measuredWidth = width
        return CGSize(width: width, height: geometry.place(ids).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        if cache.measuredWidth.map({ abs($0 - bounds.width) > 0.5 }) ?? true {
            measure(subviews, width: bounds.width)
            cache.measuredWidth = bounds.width
        }
        _ = geometry.place(ids)
        for subview in subviews {
            guard let id = subview[TranscriptRowID.self], let top = geometry.top(of: id) else { continue }
            subview.place(at: CGPoint(x: bounds.minX, y: bounds.minY + top), anchor: .topLeading,
                          proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }

    private func measure(_ subviews: Subviews, width: Double) {
        guard width > 0 else { return }
        for subview in subviews {
            guard let id = subview[TranscriptRowID.self] else { continue }
            let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
            geometry.measure(id, size.height, width: width)
        }
    }
}
