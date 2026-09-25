import AgentsKitCore
import SwiftUI

/// The app's colour vocabulary, as a closed set.
///
/// Colour is rare here and it means something. Three separate places used to say in
/// a comment that they were "the app's one use of colour", and all three had picked a
/// different colour for the same idea: an agent that needed a person was orange in the
/// list, red on a workflow row and the system accent on the phone. This is the one
/// place a state colour is named. A call site chooses a *case*, never a colour
/// (FR-001, FR-002).
///
/// Three colours rather than two. Orange and red are the pair the feature was asked
/// for; green survives because feature 014 gave it deliberately to an agent that
/// reported `done` itself (its FR-012), on the grounds that a self-reported completion
/// is the one ending the app can vouch for. Narrowing the palette would have thrown
/// that away, so the rule is three colours with one meaning each.
enum StateTint {
    /// A person is needed: a question asked mid-turn, or an outcome that says the
    /// agent cannot get further alone.
    ///
    /// Orange, and deliberately not `Color.accentColor`. The accent is what every
    /// ordinary control is drawn in, and a reader whose accent is set to orange must
    /// still be able to tell a waiting agent from a button (FR-005).
    case attention
    /// Broken, and not actionable from this screen: a folder gone, a limit reached, a
    /// runtime that needs signing in, a call that failed.
    case failure
    /// A completion the app can vouch for, because the agent said `done` itself.
    case vouched
    /// Everything else. Running, stopped, archived, and an ending nobody vouched for
    /// stay untinted (FR-006).
    case none

    /// The colour, or nil for `none`.
    ///
    /// Nil rather than a grey, so a surface that already draws in `.secondary` or
    /// `.tertiary` keeps that rather than being flattened to one shade: the hierarchy
    /// the surface had is not this type's to take away.
    var color: Color? {
        switch self {
        case .attention: return Self.orange
        case .failure: return Self.red
        case .vouched: return Self.green
        case .none: return nil
        }
    }

    /// Orange, red and green mixed for paper rather than taken from the system. The
    /// system's are tuned for a cool white and a glass sheet; on warm off-white they
    /// read as neon. These are burnt orange, brick and moss: still unmistakably the
    /// three colours the rules name, and quiet enough that a page with none of them on
    /// it looks finished rather than drained.
    private static let orange = Color(light: 0xC2410C, dark: 0xF08A4B)
    private static let red = Color(light: 0xB42318, dark: 0xF07B6E)
    private static let green = Color(light: 0x3B7A4A, dark: 0x7FBF8E)

    /// The tint as a style, or whatever the surface already draws in when there is
    /// no tint. For the sites that pick between a colour and their own grey.
    func style(or fallback: some ShapeStyle) -> AnyShapeStyle {
        color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(fallback)
    }

    /// The one mapping from an agent to a tint, so no surface decides for itself.
    ///
    /// `Agent.needsAPerson` is the input, not something redefined here: it already
    /// means exactly this — a question asked mid-turn, or an outcome reported at the
    /// end of one that needs a person — and it is what puts the agent under Needs
    /// attention in the list. `failure` is never derived from an agent; it is chosen
    /// by surfaces describing a condition, and has no single predicate.
    static func of(_ agent: Agent) -> StateTint {
        if agent.needsAPerson { return .attention }
        if agent.state == .finished, agent.report?.outcome == .done { return .vouched }
        return .none
    }
}

extension View {
    /// Draws in the tint's colour, or leaves the view's style alone for `none`.
    @ViewBuilder
    func tinted(_ tint: StateTint) -> some View {
        if let color = tint.color {
            foregroundStyle(color)
        } else {
            self
        }
    }
}
