import AgentsKit
import SwiftUI

/// One option a runtime advertises.
///
/// Nothing here knows what a model or a mode is. The choices come from the runtime and
/// the order comes from its category.
struct OptionMenu: View {
    let option: ConfigOption
    @Binding var chosen: JSONValue?

    var body: some View {
        SelectCapsule(name: option.name, title: option.closedTitle(for: chosen)) { dismiss in
            ForEach(option.options ?? []) { choice in
                SelectChoice(title: choice.name,
                             description: choice.description,
                             isChosen: choice.value == (chosen ?? option.currentValue)) {
                    chosen = choice.value
                    dismiss()
                }
            }
        }
    }
}
