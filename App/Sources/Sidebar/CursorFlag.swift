import AppKit
import SwiftUI

/// Whose caret is whose on a live page.
///
/// Two things can type on one page: the agent, whose words arrive through the file and
/// are typed out by `LivePage`, and the person, in the one passage they have open. Once
/// both are moving, a bare caret no longer says which is which. So each carries its
/// owner's name above it, the way a shared document does — the agent's in blue, the
/// person's in the system accent, the colour the system already draws their own
/// insertion point in.
struct CursorFlag: Hashable {
    var name: String
    var color: Color

    /// The agent's, named as its runtime is everywhere else in the app: "Claude".
    static func agent(_ name: String) -> CursorFlag {
        CursorFlag(name: name, color: .blue)
    }

    /// The person's, by their first name: "Alex".
    static let person = CursorFlag(name: personName, color: Color(nsColor: .controlAccentColor))

    private static let personName: String = {
        let full = NSFullUserName()
        return full.split(separator: " ").first.map(String.init) ?? NSUserName()
    }()

    /// The name, as the one `Text` both flags are drawn from, so the pill above the
    /// person's caret and the one the renderer draws above the agent's are the same.
    var label: Text {
        Text(name).stepped(.fine).fontWeight(.semibold).foregroundStyle(.white)
    }

    /// The agent's caret: a glyph at the end of the typed text, in the agent's colour,
    /// carrying the flag as an attribute for `CaretFlagRenderer` to find.
    var caret: Text {
        Text("▍").foregroundStyle(color).customAttribute(CaretAttribute(flag: self))
    }

    static let inset = EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4)
    static let radius: CGFloat = 3
    /// Between the bottom of the flag and the top of the line it stands on.
    static let gap: CGFloat = 1
}

/// The person's flag, as a view: stood above their caret by `PassageEditor`, which is
/// the one that knows where the caret is.
struct CursorFlagLabel: View {
    let flag: CursorFlag

    var body: some View {
        flag.label
            .padding(CursorFlag.inset)
            .background(flag.color, in: RoundedRectangle(cornerRadius: CursorFlag.radius))
            .fixedSize()
            .allowsHitTesting(false)
    }
}

/// Marks the run of text that is the agent's caret.
struct CaretAttribute: TextAttribute {
    let flag: CursorFlag
}

/// Draws a passage's text as it would be drawn anyway, and above the agent's caret, its
/// flag.
///
/// The caret is the last glyph of the typed text, and only the text's own layout knows
/// where that glyph landed — which line it wrapped to, how far along. A renderer is
/// handed that layout, so the flag goes exactly over the caret and costs the text
/// nothing: it takes no space in the line and moves no word, which a label typed into
/// the text itself would have done on every step.
struct CaretFlagRenderer: TextRenderer {
    /// None. Room asked for here is laid out as if it were text on the Mac: 120 points
    /// to the right made a passage being typed wider than the page, with the ends of
    /// its lines cut off until the caret left it. A flag drawn above a block's first
    /// line is not clipped without it.
    var displayPadding: EdgeInsets { EdgeInsets() }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                context.draw(run)
                guard let caret = run[CaretAttribute.self] else { continue }
                let bounds = run.typographicBounds.rect
                let name = context.resolve(caret.flag.label)
                let size = name.measure(in: CGSize(width: 400, height: 100))
                let inset = CursorFlag.inset
                let pill = CGRect(x: bounds.minX,
                                  y: bounds.minY - CursorFlag.gap - size.height - inset.top - inset.bottom,
                                  width: size.width + inset.leading + inset.trailing,
                                  height: size.height + inset.top + inset.bottom)
                context.fill(RoundedRectangle(cornerRadius: CursorFlag.radius).path(in: pill),
                             with: .color(caret.flag.color))
                context.draw(name, at: CGPoint(x: pill.minX + inset.leading, y: pill.minY + inset.top),
                             anchor: .topLeading)
            }
        }
    }
}
