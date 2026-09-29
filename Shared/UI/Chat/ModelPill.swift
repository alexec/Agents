import AgentsKitCore
import SwiftUI

/// How the agent thinks, as one pill: "<model> <effort> <Fast>".
///
/// Everything a runtime advertises that is not about permission sits behind it. The
/// menu lists the models; effort is a submenu, and anything on or off (fast mode) is a
/// toggle. Anything else the runtime sends gets a submenu of its own name, so a new
/// option still appears rather than disappearing.
struct ModelPill: View {
    /// The runtime's options, permission ones already left out.
    let options: [ConfigOption]
    let binding: (ConfigOption) -> Binding<JSONValue?>

    private var model: ConfigOption? {
        options.first { $0.category == "model" } ?? options.first { !$0.isBoolean }
    }

    private var effort: ConfigOption? {
        options.first { $0.category == "thought_level" && $0.id != model?.id }
    }

    private var rest: [ConfigOption] {
        options.filter { $0.id != model?.id && $0.id != effort?.id }
    }

    var body: some View {
        Menu {
            if let model { choices(of: model) }
            if let effort {
                Menu(effort.name) { choices(of: effort) }
            }
            ForEach(rest) { option in
                if option.isBoolean {
                    Toggle(option.name, isOn: isOn(option))
                } else {
                    Menu(option.name) { choices(of: option) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down")
                    // Decorative: a glyph in a capsule, not text (FR-015).
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, TouchTarget.capsuleVertical)
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .appText(.fine)
        .fixedSize()
        .paperRaised(in: .capsule)
        .help(options.map(\.name).joined(separator: ", "))
    }

    /// The model and its effort where either is not the default — "Default" where
    /// neither is — and the name of each switch that is on.
    private var title: String {
        var words: [String] = []
        if let model, !isDefault(model) { words.append(Self.bare(model.closedTitle(for: binding(model).wrappedValue))) }
        if let effort, !isDefault(effort) { words.append(effort.closedTitle(for: binding(effort).wrappedValue)) }
        if words.isEmpty { words.append("Default") }
        for option in rest where option.isBoolean && isOn(option).wrappedValue {
            words.append(Self.short(option.name))
        }
        return words.joined(separator: " ")
    }

    /// Nothing chosen, or a choice the runtime calls its default.
    private func isDefault(_ option: ConfigOption) -> Bool {
        guard let value = binding(option).wrappedValue ?? option.currentValue, value != .null else { return true }
        if value.stringValue?.lowercased() == "default" { return true }
        let name = option.closedTitle(for: value).lowercased()
        return name.hasPrefix("default") || name.hasSuffix("runtime default")
    }

    /// "Default (recommended)" says "Default": the aside is for the menu, not the pill.
    static func bare(_ name: String) -> String {
        guard let open = name.firstIndex(of: "("), name.hasSuffix(")") else { return name }
        let trimmed = name[..<open].trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name : trimmed
    }

    /// "Fast mode" says "Fast" in the pill: the pill is already a list of modes.
    static func short(_ name: String) -> String {
        name.lowercased().hasSuffix(" mode") ? String(name.dropLast(5)) : name
    }

    /// Each choice as a checked line, the way a menu marks the one in force.
    @ViewBuilder
    private func choices(of option: ConfigOption) -> some View {
        let chosen = binding(option)
        ForEach(Array(option.groups.enumerated()), id: \.offset) { _, group in
            Section(group.name ?? "") {
                ForEach(group.choices) { choice in
                    Toggle(choice.name, isOn: Binding(
                        get: { (chosen.wrappedValue ?? option.currentValue) == choice.value },
                        set: { if $0 { chosen.wrappedValue = choice.value } }))
                }
            }
        }
    }

    private func isOn(_ option: ConfigOption) -> Binding<Bool> {
        let chosen = binding(option)
        return Binding(
            get: { (chosen.wrappedValue ?? option.currentValue)?.boolValue ?? false },
            set: { chosen.wrappedValue = .bool($0) })
    }
}
