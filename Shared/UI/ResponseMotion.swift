import SwiftUI

/// How long the app moves when it answers a person (#4797, `specs/4777-fast/spec.md`).
///
/// Response motion is 150 ms or less: a strip or a toast that comes or goes, a sheet's
/// page, a fold that opens, a scroll to a line, a line that is lit and goes back. The
/// web page uses the same 150 ms (`Web/src/app.css`).
///
/// Loops (pulses, shimmer, a spinner) and celebrations (badges, the Multiplier, the
/// Huddle) are not response motion and keep their own times.
enum ResponseMotion {
    /// The longest a response motion takes, in seconds.
    static let seconds: Double = 0.15

    /// A strip, a toast, a fold, a scroll or a highlight.
    static let response: Animation = .easeOut(duration: seconds)

    /// A sheet's page or a pane that changes: a spring, but no longer than `response`.
    static let snappy: Animation = .snappy(duration: seconds)
}
