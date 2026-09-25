import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The four sizes text is drawn at in either app, and the monospace one.
///
/// 018 gave the chat transcript a scale of its own and a test that held it. It worked,
/// and it stopped at the transcript's edge: the forty views around it went on choosing
/// between eight semantic styles by hand, at a hundred and seventy-seven call sites,
/// with nothing arbitrating. What settled out of that was a page drawn a step below the
/// platform — `.callout` was doing body duty in sixty-seven places and `.body` appeared
/// nowhere — around a chat drawn at the platform's own size. The complaint 018 was
/// written for came back pointing the other way.
///
/// So the scale is now the app's rather than the chat's, and it is anchored where the
/// reading actually happens: `reading` is the size the prompt field has always been.
/// Everything else is two points either side of it on the Mac and two on the phone.
///
/// A step is a position on the platform's semantic scale, never a point size, so the
/// platform keeps the numbers and the reader's text-size setting keeps working
/// (FR-015). Decorative glyphs inside capsules and badges are not text and are exempt;
/// each is marked as such in a comment where it sits.
///
///     STEP          MAC                  iOS
///     title         .title        22     .title        28
///     reading       .title3       15     .body         17
///     supporting    .body         13     .subheadline  15
///     fine          .subheadline  11     .footnote     13
///     code          .body    mono 13     .subheadline mono 15
///
/// Paper (the theme in `Paper.swift`) sets `title`, `reading` and `supporting` in New
/// York, the system serif, because those are the steps a person reads at length. `fine`
/// stays in SF: it is chrome, and small serif chrome reads as fussy. `code` stays mono.
///
/// There is no `heading` step. A heading is `reading` with a weight on it, which is how
/// `.headline` has always related to `.body` on Apple's platforms, and one fewer name
/// to choose wrongly.
enum TextStep {
    /// A page's own title, and the one number a page exists to report. Nothing else:
    /// a section header is `fine` with a weight, not a small title.
    case title

    /// The size everything is read at unless there is a reason otherwise — messages,
    /// row titles, form labels, body copy, the document page, and the prompt field
    /// this step was measured from. When in doubt it is this one.
    case reading

    /// A step down, for what sits under something at `reading` and explains it: a row's
    /// description, a thought, a tool's title, secondary detail.
    case supporting

    /// Two steps down, and as far down as anything goes: timestamps, counts, badge
    /// text, section headers, and the chrome on the small buttons around the prompt.
    case fine

    /// Code, diffs, command names and file paths. Drawn at `supporting`'s size rather
    /// than `reading`'s, because monospace runs visually larger than the prose around
    /// it and matching the number makes it look bigger.
    case code

    var font: Font {
        #if os(macOS)
        switch self {
        case .title: return .system(.title, design: .serif)
        case .reading: return .system(.title3, design: .serif)
        case .supporting: return .system(.body, design: .serif)
        case .fine: return .subheadline
        case .code: return .body.monospaced()
        }
        #else
        switch self {
        case .title: return .system(.title, design: .serif)
        case .reading: return .system(.body, design: .serif)
        case .supporting: return .system(.subheadline, design: .serif)
        case .fine: return .footnote
        case .code: return .subheadline.monospaced()
        }
        #endif
    }
}

#if os(macOS)
extension TextStep {
    /// The same step for an AppKit text view, which takes an `NSFont` rather than a
    /// `Font`. Resolved here for the reason every other step is: this is the one place
    /// a step becomes a size.
    var nsFont: NSFont {
        switch self {
        case .title: return Self.serif(.title1)
        case .reading: return Self.serif(.title3)
        case .supporting: return Self.serif(.body)
        case .fine: return .preferredFont(forTextStyle: .subheadline)
        case .code: return .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                                                  weight: .regular)
        }
    }

    /// New York at a text style's size, falling back to the system face if the serif
    /// design is ever unavailable.
    private static func serif(_ style: NSFont.TextStyle) -> NSFont {
        let base = NSFont.preferredFont(forTextStyle: style)
        guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
        return NSFont(descriptor: serif, size: base.pointSize) ?? base
    }
}
#endif

extension Text {
    /// A step of the scale on a `Text` that has to stay a `Text` — one resolved inside
    /// a `GraphicsContext`, or interpolated into another. `appText` returns a view, and
    /// a text renderer cannot draw a view.
    func stepped(_ step: TextStep) -> Text {
        font(step.font)
    }
}

extension View {
    /// Sets the text to a step of the scale. The Mac and the phone resolve the same
    /// step to their own font, because this is the only place a step is resolved
    /// (FR-013). A weight goes on afterwards with `.fontWeight(_:)`.
    func appText(_ step: TextStep) -> some View {
        font(step.font)
    }
}

extension TextStep {
    /// A Markdown heading, which is not a step.
    ///
    /// The four steps run from `title` downwards and leave no room between `title` and
    /// `reading` for a second heading level, and Markdown needs three. So headings keep
    /// a relative ladder of their own — but here, resolved once for both apps, rather
    /// than as a ternary copied into each renderer.
    ///
    /// Anchored above `reading` rather than below it. Before this the ladder ran
    /// `.title3` / `.headline` / `.subheadline`, which was one step above the old prose
    /// and two below it; with prose now at `.title3` itself, an `h1` would have matched
    /// the paragraph under it and an `h3` would have been smaller.
    ///
    ///     LEVEL   MAC                  iOS
    ///     1       .title        22     .title   28
    ///     2       .title2       17     .title2  22
    ///     3+      reading       15     reading  17
    ///
    /// All semibold, because what makes a heading a heading at the bottom of the ladder
    /// is the weight, not the size.
    static func heading(level: Int) -> Font {
        #if os(macOS)
        let style: Font.TextStyle = level <= 1 ? .title : level == 2 ? .title2 : .title3
        #else
        let style: Font.TextStyle = level <= 1 ? .title : level == 2 ? .title2 : .body
        #endif
        let font = Font.system(style, design: .serif)
        return font.weight(.semibold)
    }
}
