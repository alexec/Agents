import AgentsKitCore
import SwiftUI

/// A machine row's icon (#4113): the kind in its shape, the state in its colour, so the row
/// has no dot. Amber pulses while the machine changes, except under Reduce Motion.
struct MachineIconView: View {
    let symbol: String
    let icon: MachineIcon
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: symbol)
            .sidebarMark(style)
            .symbolEffect(.pulse, isActive: icon == .busy && !reduceMotion)
            .accessibilityHidden(true)
    }

    private var style: AnyShapeStyle {
        switch icon {
        case .accent: AnyShapeStyle(Paper.accent)
        case .busy, .attention: StateTint.attention.style(or: .secondary)
        case .failure: StateTint.failure.style(or: .secondary)
        case .stopped: AnyShapeStyle(.secondary)
        }
    }
}
