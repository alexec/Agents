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
/// Paper sets `title`, `reading`, `supporting` and `fine` in the system sans-serif.
/// `code` stays in the system monospace.
///
/// There is no `heading` step. A heading is `reading` with a weight on it, which is how
/// `.headline` has always related to `.body` on Apple's platforms, and one fewer name
/// to choose wrongly.
enum TextStep {
    /// A page's own title, and the one number a page exists to report. Nothing else:
    /// a section header is `reading` with a weight (`SectionHeading`), not a small title.
    case title

    /// The size everything is read at unless there is a reason otherwise — messages,
    /// row titles, form labels, body copy, the document page, and the prompt field
    /// this step was measured from. When in doubt it is this one.
    case reading

    /// A step down, for what sits under something at `reading` and explains it: a row's
    /// description, a thought, a tool's title, secondary detail.
    case supporting

    /// Two steps down, and as far down as anything goes: timestamps, counts, badge
    /// text, and the chrome on the small buttons around the prompt. A section heading
    /// is `reading` with a weight (`SectionHeading`), not this step.
    case fine

    /// Code, diffs, command names and file paths. Drawn at `supporting`'s size rather
    /// than `reading`'s, because monospace runs visually larger than the prose around
    /// it and matching the number makes it look bigger.
    case code

    var font: Font {
        #if os(macOS)
        switch self {
        case .title: return .system(.title)
        case .reading: return .system(.title3)
        case .supporting: return .system(.body)
        case .fine: return .subheadline
        case .code: return .body.monospaced()
        }
        #else
        switch self {
        case .title: return .system(.title)
        case .reading: return .system(.body)
        case .supporting: return .system(.subheadline)
        case .fine: return .footnote
        case .code: return .subheadline.monospaced()
        }
        #endif
    }
}

extension View {
    /// A glyph that is not text — a status mark, a capsule's chevron — at a fixed size
    /// that still grows with the system's text size, so it keeps its place beside the
    /// text it marks.
    func glyph(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledGlyph(points: size, weight: weight))
    }

    /// The same for a glyph sized by a text style rather than a number, which moves
    /// with the system's text size by itself.
    func glyph(_ style: Font.TextStyle) -> some View {
        font(.system(style))
    }
}

private struct ScaledGlyph: ViewModifier {
    let points: CGFloat
    let weight: Font.Weight
    /// 1 at the default size, larger with Dynamic Type on the phone.
    @ScaledMetric private var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content.font(.system(size: points * scale, weight: weight))
    }
}

#if os(macOS)
extension TextStep {
    /// The same step for an AppKit text view, which takes an `NSFont` rather than a
    /// `Font`. Resolved here for the reason every other step is: this is the one place
    /// a step becomes a size.
    var nsFont: NSFont {
        switch self {
        case .title: return .preferredFont(forTextStyle: .title1)
        case .reading: return .preferredFont(forTextStyle: .title3)
        case .supporting: return .preferredFont(forTextStyle: .body)
        case .fine: return .preferredFont(forTextStyle: .subheadline)
        case .code: return .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize,
                                                  weight: .regular)
        }
    }

    /// The same on a zoomed page (#1419), for the passage editor.
    func nsFont(zoom: CGFloat) -> NSFont {
        guard zoom != 1 else { return nsFont }
        return nsFont.withSize(nsFont.pointSize * zoom)
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

extension EnvironmentValues {
    /// How much larger than its step a Markdown page's text is drawn (#1419). Only a
    /// page sets it; everywhere else it is 1, and the chat and the sidebar draw as
    /// they always did.
    @Entry var textZoom: CGFloat = 1
}

extension View {
    /// Sets the text to a step of the scale. The Mac and the phone resolve the same
    /// step to their own font, because this is the only place a step is resolved
    /// (FR-013). A weight goes on afterwards with `.fontWeight(_:)`.
    ///
    /// The size is the system's (#1034): Dynamic Type on the phone, and the Mac's own
    /// text size where SwiftUI applies it. A page's zoom (`textZoom`) multiplies it.
    func appText(_ step: TextStep) -> some View {
        modifier(SteppedText(step: step))
    }
}

private struct SteppedText: ViewModifier {
    let step: TextStep
    @Environment(\.textZoom) private var zoom
    @Environment(\.dynamicTypeSize) private var dynamicType

    func body(content: Content) -> some View {
        content.font(step.zoomedFont(zoom, dynamicType: dynamicType))
    }
}

extension TextStep {
    /// The step at a page's zoom (#1419). At 1 it is the semantic font itself, so
    /// nothing changes where nothing is zoomed. Zoomed, a semantic style cannot be
    /// scaled, so it becomes the point size the style resolves to, times the zoom: on
    /// the phone at the environment's Dynamic Type size, which the Mac does not have.
    func zoomedFont(_ zoom: CGFloat, dynamicType: DynamicTypeSize) -> Font {
        guard zoom != 1 else { return font }
        #if os(macOS)
        let points = nsFont.pointSize
        #else
        let points = uiFont(dynamicType: dynamicType).pointSize
        #endif
        return Self.sized(points * zoom, monospaced: self == .code)
    }

    fileprivate static func sized(_ points: CGFloat, monospaced: Bool) -> Font {
        monospaced ? .system(size: points, design: .monospaced) : .system(size: points)
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
        return Font.system(style).weight(.semibold)
        #else
        let style: Font.TextStyle = level <= 1 ? .title : level == 2 ? .title2 : .body
        let font = Font.system(style)
        return font.weight(.semibold)
        #endif
    }

    /// The same heading on a zoomed page (#1419): the ladder's point size times the
    /// zoom, and the ladder itself at 1.
    static func heading(level: Int, zoom: CGFloat, dynamicType: DynamicTypeSize) -> Font {
        guard zoom != 1 else { return heading(level: level) }
        #if os(macOS)
        let style: NSFont.TextStyle = level <= 1 ? .title1 : level == 2 ? .title2 : .title3
        let points = NSFont.preferredFont(forTextStyle: style).pointSize
        #else
        let style: UIFont.TextStyle = level <= 1 ? .title1 : level == 2 ? .title2 : .body
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicType))
        let points = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        #endif
        return sized(points * zoom, monospaced: false).weight(.semibold)
    }
}

#if os(iOS)
extension TextStep {
    /// The same step for a UIKit text view: the page's passage editor (034). The
    /// phone's side of `nsFont`, resolved here for the same reason.
    var uiFont: UIFont {
        switch self {
        case .title: return .preferredFont(forTextStyle: .title1)
        case .reading: return .preferredFont(forTextStyle: .body)
        case .supporting: return .preferredFont(forTextStyle: .subheadline)
        case .fine: return .preferredFont(forTextStyle: .footnote)
        case .code: return .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize,
                                                  weight: .regular)
        }
    }

    /// The same at the text size SwiftUI's environment says, which a zoomed page
    /// (#1419) multiplies.
    func uiFont(dynamicType: DynamicTypeSize) -> UIFont {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicType))
        let style: UIFont.TextStyle
        switch self {
        case .title: style = .title1
        case .reading: style = .body
        case .supporting, .code: style = .subheadline
        case .fine: style = .footnote
        }
        let base = UIFont.preferredFont(forTextStyle: style, compatibleWith: traits)
        return self == .code ? .monospacedSystemFont(ofSize: base.pointSize, weight: .regular) : base
    }

    /// The same on a zoomed page (#1419), for the passage editor. Scaled through the
    /// step's own metrics, so the text view still follows Dynamic Type.
    func uiFont(zoom: CGFloat) -> UIFont {
        guard zoom != 1 else { return uiFont }
        let style: UIFont.TextStyle = switch self {
        case .title: .title1
        case .reading: .body
        case .supporting, .code: .subheadline
        case .fine: .footnote
        }
        let atDefault = UIFont.preferredFont(forTextStyle: style,
                                             compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        return UIFontMetrics(forTextStyle: style).scaledFont(for: atDefault.withSize(atDefault.pointSize * zoom))
    }

}
#endif
