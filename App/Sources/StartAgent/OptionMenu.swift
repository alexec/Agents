import AgentsKit
import SwiftUI

/// One option a runtime advertises, as a menu that reads like a sentence when closed.
///
/// Nothing here knows what a model or a mode is. The choices come from the runtime, the
/// order comes from its category, and whether the option's name is shown comes from
/// whether its choices say what they are on their own.
struct OptionMenu: View {
    let option: ConfigOption
    let title: String
    @Binding var chosen: [String: JSONValue]

    var body: some View {
        Menu(title) {
            ForEach(option.options ?? []) { choice in
                Button {
                    chosen[option.id] = choice.value
                } label: {
                    // Inside the menu the name is enough: what is being chosen is
                    // already said by the control that opened it.
                    if choice.value == (chosen[option.id] ?? option.currentValue) {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        // A real control, so it reacts to the pointer.
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(option.description ?? option.name)
    }
}
