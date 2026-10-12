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

/// How large a person has chosen the app's text to be (#750): the default and two steps
/// up, and nothing smaller. Per device, like the appearance, and never sent anywhere.
///
/// The Mac draws its own steps larger, because macOS SwiftUI does not move its text styles
/// with `dynamicTypeSize`; `appText` reads this from the environment and multiplies.
/// The phone moves the system's Dynamic Type up a step or two instead, so the reader's own
/// text-size setting is built on rather than replaced. Glyphs drawn beside text — a
/// status mark, a dot, a capsule's chevron — take `scale` on both, so a row keeps its
/// shape at every size.
enum TextSize: String, CaseIterable, Identifiable, Sendable {
    // One line, so the scale's own check counts five steps above and not these.
    case standard = "default", large, larger

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: "Default"
        case .large: "Large"
        case .larger: "Larger"
        }
    }

    /// What a size drawn by hand is multiplied by: about two points a step at the Mac's
    /// body size, as Dynamic Type's own steps are on the phone.
    var scale: CGFloat {
        switch self {
        case .standard: 1
        case .large: 1.15
        case .larger: 1.3
        }
    }

    /// `--text-size default|large|larger`, which wins over the stored choice for the life
    /// of the process: a scratch copy can be walked at each size without anybody's setting
    /// being changed to get there.
    static let launchOverride: TextSize? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--text-size"), index + 1 < arguments.count
        else { return nil }
        return TextSize(rawValue: arguments[index + 1])
    }()

    #if os(iOS)
    /// The system's Dynamic Type, moved up this many steps. Into the accessibility sizes
    /// if the reader is already at the top of the ordinary ones.
    func applied(to size: DynamicTypeSize) -> DynamicTypeSize {
        let steps = switch self {
        case .standard: 0
        case .large: 1
        case .larger: 2
        }
        let all = DynamicTypeSize.allCases
        guard let index = all.firstIndex(of: size) else { return size }
        return all[min(index + steps, all.count - 1)]
    }
    #endif
}

extension EnvironmentValues {
    /// Set once at each app's root from the person's choice.
    @Entry var textSize = TextSize.standard
}

extension View {
    /// A glyph that is not text — a status mark, a capsule's chevron — at a fixed size
    /// that still grows with the person's text size, so it keeps its place beside the
    /// text it marks.
    func glyph(size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledGlyph(points: size, weight: weight))
    }

    /// The same for a glyph sized by a text style rather than a number. The phone moves
    /// the style with Dynamic Type already; the Mac multiplies.
    func glyph(_ style: Font.TextStyle) -> some View {
        modifier(StyledGlyph(style: style))
    }
}

private struct ScaledGlyph: ViewModifier {
    let points: CGFloat
    let weight: Font.Weight
    @Environment(\.textSize) private var size

    func body(content: Content) -> some View {
        content.font(.system(size: points * size.scale, weight: weight))
    }
}

private struct StyledGlyph: ViewModifier {
    let style: Font.TextStyle
    @Environment(\.textSize) private var size

    func body(content: Content) -> some View {
        #if os(macOS)
        if size == .standard {
            content.font(.system(style))
        } else {
            content.font(.system(size: NSFont.preferredFont(forTextStyle: style.appKit).pointSize * size.scale))
        }
        #else
        content.font(.system(style))
        #endif
    }
}

#if os(macOS)
private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

extension TextStep {
    /// The step at a person's text size. The default is the semantic style itself, as it
    /// always was; a larger one is the same face at the style's size times the scale.
    func font(_ size: TextSize) -> Font {
        guard size != .standard else { return font }
        let points = nsFont.pointSize * size.scale
        return self == .code ? .system(size: points, design: .monospaced) : .system(size: points)
    }

    /// `nsFont` at a person's text size, for the text views that take one.
    func nsFont(_ size: TextSize) -> NSFont {
        let base = nsFont
        guard size != .standard else { return base }
        return NSFont(descriptor: base.fontDescriptor, size: base.pointSize * size.scale) ?? base
    }

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

}
#endif

extension Text {
    /// A step of the scale on a `Text` that has to stay a `Text` — one resolved inside
    /// a `GraphicsContext`, or interpolated into another. `appText` returns a view, and
    /// a text renderer cannot draw a view.
    func stepped(_ step: TextStep, _ size: TextSize = .standard) -> Text {
        #if os(macOS)
        font(step.font(size))
        #else
        font(step.font)
        #endif
    }
}

extension View {
    /// Sets the text to a step of the scale. The Mac and the phone resolve the same
    /// step to their own font, because this is the only place a step is resolved
    /// (FR-013). A weight goes on afterwards with `.fontWeight(_:)`.
    ///
    /// On the Mac it reads the person's text size (#750) from the environment; on the
    /// phone the root moves Dynamic Type instead, and the semantic style follows it.
    func appText(_ step: TextStep) -> some View {
        #if os(macOS)
        modifier(MacSteppedText(step: step))
        #else
        font(step.font)
        #endif
    }
}

#if os(macOS)
private struct MacSteppedText: ViewModifier {
    let step: TextStep
    @Environment(\.textSize) private var size

    func body(content: Content) -> some View {
        content.font(step.font(size))
    }
}
#endif

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
    static func heading(level: Int, size: TextSize = .standard) -> Font {
        #if os(macOS)
        let style: Font.TextStyle = level <= 1 ? .title : level == 2 ? .title2 : .title3
        guard size != .standard else { return Font.system(style).weight(.semibold) }
        let base = NSFont.preferredFont(forTextStyle: style.appKit).pointSize
        return .system(size: base * size.scale, weight: .semibold)
        #else
        let style: Font.TextStyle = level <= 1 ? .title : level == 2 ? .title2 : .body
        let font = Font.system(style)
        return font.weight(.semibold)
        #endif
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

}
#endif
