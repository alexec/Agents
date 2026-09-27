import AgentsKitCore
import SwiftUI

/// The working spinner, drawn by us so every one on a screen turns in step.
///
/// The system's `ProgressView()` starts its turn when it appears, and nothing can set
/// its phase, so a column of working agents spun out of step with each other and with
/// the chat's working line. This draws the same wheel, with the lit spoke read off the
/// clock (`SpinnerClock`), so all of them land on the same spoke on the same frame.
///
/// The spokes follow the platform's own: twelve on the Mac, eight on the phone. The
/// timeline ticks once a spoke rather than every frame, so a list of working agents
/// redraws a dozen times a second, not sixty. Like the system spinner it keeps turning
/// under Reduce Motion: a still wheel would read as stuck.
struct SyncedSpinner: View {
    /// The wheel's width and height, in points.
    var diameter: CGFloat

    #if os(macOS)
    private static let spokes = 12
    #else
    private static let spokes = 8
    #endif

    var body: some View {
        TimelineView(.periodic(from: SpinnerClock.epoch, by: SpinnerClock.tick(spokes: Self.spokes))) { context in
            let step = SpinnerClock.step(at: context.date, spokes: Self.spokes)
            ZStack {
                ForEach(0..<Self.spokes, id: \.self) { spoke in
                    Capsule()
                        .frame(width: diameter * 0.09, height: diameter * 0.28)
                        .offset(y: -diameter * 0.32)
                        .rotationEffect(.degrees(Double(spoke) * 360 / Double(Self.spokes)))
                        .opacity(SpinnerClock.opacity(ofSpoke: spoke, step: step, spokes: Self.spokes))
                }
            }
            .foregroundStyle(.secondary)
            // A parent's animation would fade one spoke into the next. The wheel ticks.
            .transaction { $0.animation = nil }
        }
        .frame(width: diameter, height: diameter)
        // One element and no words of its own: the caller says what it means, and a
        // label stacked over a child's label overflows AppKit's stack.
        .accessibilityElement()
    }
}
