import AgentsKit
import SwiftUI

/// The options a runtime advertises, drawn from what it said rather than from anything
/// this app knows.
///
/// Rendered by `type` and grouped by `category`. No model, no mode and no effort level
/// is named anywhere in this file, which is why a runtime shipping a new one needs no
/// change here.
struct OptionsForm: View {
    let options: [ConfigOption]
    @Binding var chosen: [String: JSONValue]

    private var categories: [String] {
        var seen: [String] = []
        for option in options {
            let category = option.category ?? "Options"
            if !seen.contains(category) { seen.append(category) }
        }
        return seen
    }

    var body: some View {
        ForEach(categories, id: \.self) { category in
            Section(title(for: category)) {
                ForEach(options.filter { ($0.category ?? "Options") == category }) { option in
                    row(for: option)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for option: ConfigOption) -> some View {
        // Only `select` is drawn. An option of a type we do not know is left out
        // rather than guessed at, and leaving it out never stops an agent starting.
        if option.type == "select", let choices = option.options {
            Picker(option.name, selection: binding(for: option)) {
                ForEach(choices) { choice in
                    Text(choice.name).tag(choice.value)
                }
            }
            .help(option.description ?? "")
        }
    }

    private func binding(for option: ConfigOption) -> Binding<JSONValue> {
        Binding(
            get: { chosen[option.id] ?? option.currentValue ?? .null },
            set: { chosen[option.id] = $0 })
    }

    /// The runtime's own category names, tidied for a form rather than translated.
    private func title(for category: String) -> String {
        category
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
