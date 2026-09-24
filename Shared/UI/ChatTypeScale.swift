import SwiftUI

/// The four sizes a chat entry may be drawn at.
///
/// The transcript used to choose a size at sixty call sites between the two apps,
/// and the spread was four steps: prose fell through to the platform default while
/// placeholders were `.footnote` on the Mac and `.callout` on the phone, and fine
/// print was `.caption2`. The page read smaller than the text in it, because most of
/// what was on the page was the smaller part. Each entry kind now names a step; no
/// entry names a font (FR-009).
///
/// A step is a position on the platform's semantic scale, never a point size, so the
/// platform keeps the numbers and the reader's text-size setting keeps working
/// (FR-015). Decorative glyphs inside capsules and badges are not text and are
/// exempt; each is marked as such in a comment where it sits.
enum ChatTypeStep {
    /// Agent and person messages, at the platform's standard reading size (FR-010).
    case prose
    /// Thoughts, tool titles, the app's own question, resource links, placeholders
    /// for what cannot be drawn. Exactly one step below `prose` (FR-011).
    case supporting
    /// Timestamps, block labels, language tags, per-entry metadata. Two steps below
    /// `prose`, which is as far as the transcript goes (FR-012).
    case fine
    /// Code blocks, diffs, command names. One step below `prose`, the same as
    /// `supporting`, because monospace runs visually larger than the prose around
    /// it (FR-016).
    case code

    var font: Font {
        switch self {
        case .prose: return .body
        case .supporting: return .callout
        case .fine: return .caption
        case .code: return .callout.monospaced()
        }
    }
}

extension View {
    /// Sets the text to a step of the chat scale. The Mac and the phone resolve the
    /// same step to the same font, because this is the only place a step is resolved
    /// (FR-013).
    func chatText(_ step: ChatTypeStep) -> some View {
        font(step.font)
    }
}
