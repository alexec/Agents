import AgentsKit
import SwiftUI

/// One option a runtime advertises.
///
/// Nothing here knows what a model or a mode is. The choices come from the runtime, the
/// order comes from its category, and the control comes from its kind.
struct OptionMenu: View {
    let option: ConfigOption
    @Binding var chosen: JSONValue?

    var body: some View {
        switch option.kind {
        case .boolean:
            BooleanCapsule(name: option.name, isOn: isOn) { chosen = .bool($0) }
        case .select(let groups):
            SelectCapsule(name: option.name, title: option.closedTitle(for: chosen)) { dismiss in
                ForEach(groups) { group in
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

    private var isOn: Bool {
        (chosen ?? option.currentValue)?.boolValue ?? false
    }
}
