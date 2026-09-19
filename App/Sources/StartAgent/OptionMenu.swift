import AgentsKit
import SwiftUI

/// One option a runtime advertises, as a menu that reads as its chosen value.
///
/// Nothing here knows what a model or a mode is. The choices come from the runtime and
/// the order comes from its category. There is no label: which setting it is comes from
/// where it sits and from opening it.
struct OptionMenu: View {
    let option: ConfigOption
    @Binding var chosen: JSONValue?

    var body: some View {
        Menu(option.closedTitle(for: chosen)) {
            ForEach(option.options ?? []) { choice in
                Button {
                    chosen = choice.value
                } label: {
                    // Inside the menu the name is enough: what is being chosen is
                    // already said by the control that opened it.
                    if choice.value == (chosen ?? option.currentValue) {
                        Label(choice.name, systemImage: "checkmark")
                    } else {
                        Text(choice.name)
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .font(.footnote)
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        // A real control, so it reacts to the pointer.
        .glassEffect(.regular.interactive(), in: .capsule)
        .help(option.description ?? option.name)
    }
}
