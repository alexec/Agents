import AgentsKitCore
import SwiftUI

/// The working spinner, drawn by us so every one on a screen turns in step.
///
/// The system's `ProgressView()` starts its turn when it appears, and nothing can set
/// its phase, so a column of working agents spun out of step with each other and with
/// the chat's working line. This draws a circle-notch, an open ring with round caps
/// (#1606), turned to the angle read off the clock (`SpinnerClock`), so all of them
/// show the notch at the same angle on the same frame.
///
/// The notch glides, so the timeline redraws at most thirty times a second, and only
/// the rotation changes from one frame to the next. Like the system spinner it keeps
/// turning under Reduce Motion: a still ring would read as stuck.
struct SyncedSpinner: View {
    /// The ring's width and height, in points.
    var diameter: CGFloat
    /// The ring's colour: grey, as the system's, except in the sidebar's marks, which are
    /// in the accent as the rest of them (#1558).
    var color: Color = .secondary

    var body: some View {
        let lineWidth = diameter * 0.12
        let ring = Circle()
            .trim(from: 0, to: 0.8)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            // Inset by half the stroke, so the ring and its caps stay in the frame.
            .padding(lineWidth / 2)
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            ring
                .rotationEffect(.degrees(SpinnerClock.angle(at: context.date)))
                // A parent's animation would ease the notch between frames. The clock sets it.
                .transaction { $0.animation = nil }
        }
        .frame(width: diameter, height: diameter)
        // One element and no words of its own: the caller says what it means, and a
        // label stacked over a child's label overflows AppKit's stack.
        .accessibilityElement()
    }
}
