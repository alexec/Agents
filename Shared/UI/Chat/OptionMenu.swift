import AgentsKitCore
import SwiftUI

/// One option a runtime advertises.
///
/// Nothing here knows what a model or a mode is. The choices come from the runtime, the
/// order comes from its category, and the control comes from its kind.
struct OptionMenu: View {
    let option: ConfigOption
    @Binding var chosen: JSONValue?
    /// Say what the control sets as well as what it is set to — "Model: Default" rather
    /// than "Default" — for a row with room for it. The Mac's prompt has; the phone's,
    /// which is a thumb's width, keeps the bare value.
    var labelled = false

    var body: some View {
        switch option.kind {
        case .boolean:
            BooleanCapsule(name: option.name, isOn: isOn, saysState: labelled) { chosen = .bool($0) }
        case .select(let groups):
            SelectCapsule(name: option.name, title: title) { dismiss in
                // By position, not by `group.id`: a group's id is its heading, and two
                // without one — the workflow page's "Runtime default" ahead of the
                // runtime's own flat list — would share it, and SwiftUI then draws the
                // first group in place of the second.
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    // A heading only where the runtime gave one. A flat list is the
                    // common case and looks exactly as it did before.
                    if let name = group.name, !name.isEmpty {
                        Text(name)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 8)
                            .padding(.top, 6)
                            .padding(.bottom, 2)
                    }
                    ForEach(group.choices) { choice in
                        SelectChoice(title: choice.name,
                                     description: choice.description,
                                     isChosen: choice.value == (chosen ?? option.currentValue)) {
                            chosen = choice.value
                            dismiss()
                        }
                    }
                }
            }
        case .unsupported:
            // Skipped rather than guessed at. It is filtered out before this, and this
            // is here so that a change upstream fails quietly rather than oddly.
            EmptyView()
        }
    }

    /// The value, or the name and the value. Never the name twice, which is what a value
    /// the runtime did not list falls back to.
    private var title: String {
        let value = option.closedTitle(for: chosen)
        guard labelled, value != option.name else { return value }
        return "\(option.name): \(value)"
    }

    private var isOn: Bool {
        (chosen ?? option.currentValue)?.boolValue ?? false
    }
}
