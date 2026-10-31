import SwiftUI

/// A sidebar row's title and the folder it is in, on one line (#936), drawn by the window's
/// and the Remote's session rows. The folder's name is whole while it takes at most
/// `placeShare` of the line, and is cut after that, so a long folder name never pushes the
/// title out (cut to "p" it said nothing, #587). The title has the rest. Two subviews, title
/// first; one is drawn alone. Set on their first text baseline, as the web's flex row does.
struct TitleAndPlace: Layout {
    var spacing: CGFloat = 5
    var placeShare: CGFloat = 0.4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews)
        let lines = zip(subviews, widths).map { $0.dimensions(in: ProposedViewSize(width: $1, height: nil)) }
        let ascent = lines.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
        let descent = lines.map { $0.height - $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
        let width = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        return CGSize(width: width, height: ascent + descent)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = widths(for: bounds.width, subviews)
        let lines = zip(subviews, widths).map { $0.dimensions(in: ProposedViewSize(width: $1, height: nil)) }
        let ascent = lines.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() where index < widths.count {
            let y = bounds.minY + ascent - lines[index][VerticalAlignment.firstTextBaseline]
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }

    /// The line's baseline, so a row's marks after it sit on it (the Remote's row).
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize,
                           subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline || guide == .lastTextBaseline else { return nil }
        let widths = widths(for: bounds.width, subviews)
        let ascent = zip(subviews, widths)
            .map { $0.dimensions(in: ProposedViewSize(width: $1, height: nil))[VerticalAlignment.firstTextBaseline] }
            .max() ?? 0
        return bounds.minY + ascent
    }

    /// The title's width and the place's: both whole when they fit, else the place up to its
    /// share, or more when the title leaves it room, and the title the rest.
    private func widths(for width: CGFloat?, _ subviews: Subviews) -> [CGFloat] {
        let ideal = subviews.prefix(2).map { $0.sizeThatFits(.unspecified).width }
        guard let width, ideal.count == 2 else { return ideal.map { min($0, width ?? $0) } }
        let room = max(0, width - spacing)
        guard ideal[0] + ideal[1] > room else { return ideal }
        let place = min(ideal[1], max(room * placeShare, room - ideal[0]))
        return [min(ideal[0], room - place), place]
    }
}
