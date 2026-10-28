import AgentsKitCore
import SwiftUI

/// The Model or Permission mode pill, in the words every runtime shares (#2658): the value
/// alone (**Balanced**, **Ask**), or **Custom** when the runtime's own setting matches none.
///
/// The menu's header names the field; each value says what it is on the runtime ("Sonnet 5
/// on Claude"). The runtime's own choices stay behind **⋯ <runtime>'s own**, which is not
/// there on Auto: Auto has no runtime yet.
struct LevelPill: View {
    let field: AutoField
    /// The value in force, by its wire name; nil is Custom.
    let chosen: String?
    /// The runtime it maps to, by name, for each value's line; nil while Auto has none.
    let runtimeName: String?
    /// Each value's cell on that runtime, for its words and whether it can be had.
    let cell: (String) -> AutoMapping?
    /// The runtime's own options behind ⋯ own, with what each is set to.
    var own: [ConfigOption] = []
    var binding: ((ConfigOption) -> Binding<JSONValue?>)?
    let choose: (String) -> Void

    private var title: String {
        guard let chosen else { return LevelWords.custom }
        return LevelWords.level(field, chosen)
    }

    var body: some View {
        Menu {
            Section(LevelWords.field(field)) {
                ForEach(LevelWords.levels(field), id: \.self) { level in
                    let c = cell(level)
                    let possible = c.map { $0.mark != .notPossible && $0.mark != .dropped } ?? true
                    Button {
                        choose(level)
                    } label: {
                        if level == chosen {
                            Label(LevelWords.level(field, level), systemImage: "checkmark")
                        } else {
                            Text(LevelWords.level(field, level))
                        }
                        if let line = line(level, c) { Text(line) }
                    }
                    .disabled(!possible)
                }
            }
            if let runtimeName, let binding, !own.isEmpty {
                Menu(LevelWords.own(runtimeName)) {
                    ForEach(own) { option in
                        if option.isBoolean {
                            Toggle(option.name, isOn: Binding(
                                get: { (binding(option).wrappedValue ?? option.currentValue)?.boolValue ?? false },
                                set: { binding(option).wrappedValue = .bool($0) }))
                        } else if own.count == 1 {
                            choices(of: option, binding(option))
                        } else {
                            Menu(option.name) { choices(of: option, binding(option)) }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                Image(systemName: "chevron.down")
                    // Decorative: a glyph in a capsule, not text (FR-015).
                    .glyph(size: 8, weight: .semibold)
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
        .help(LevelWords.field(field))
        .accessibilityLabel(LevelWords.field(field))
        .accessibilityValue(title)
    }

    /// "Sonnet 5 on Claude", or why the runtime cannot give it.
    private func line(_ level: String, _ cell: AutoMapping?) -> String? {
        guard let cell else { return nil }
        let on = runtimeName.map { " on \($0)" } ?? ""
        switch cell.mark {
        case .notPossible, .dropped:
            return [LevelWords.mark(cell.mark), cell.note].compactMap { $0 }.joined(separator: ": ")
        default:
            return cell.words + on
        }
    }

    @ViewBuilder
    private func choices(of option: ConfigOption, _ chosen: Binding<JSONValue?>) -> some View {
        ForEach(Array(option.groups.enumerated()), id: \.offset) { _, group in
            Section(group.name ?? "") {
                ForEach(group.choices) { choice in
                    if let mark = choice.setBy {
                        OrgPolicyMenuItem(name: choice.name, mark: mark)
                    } else {
                        Toggle(choice.name, isOn: Binding(
                            get: { (chosen.wrappedValue ?? option.currentValue) == choice.value },
                            set: { if $0 { chosen.wrappedValue = choice.value } }))
                    }
                }
            }
        }
    }
}

/// Which value of a field a runtime's own settings are, from the Mappings (#2658): the
/// first cell whose every option the settings have, or nil (Custom).
enum LevelMatch {
    static func level(_ field: AutoField, runtimeID: String, mappings: AutoMappings,
                      value: (String) -> JSONValue?) -> String? {
        // The more particular first: Fast and Smart set a model; Balanced may set none.
        let order: [String] = field == .model ? ["fast", "smart", "balanced"] : LevelWords.levels(field)
        for level in order {
            guard let cell = mappings.cell(runtimeID, field, level), let options = cell.native?.options,
                  cell.mark != .notPossible else { continue }
            if options.isEmpty { continue }
            if options.allSatisfy({ value($0.key) == $0.value }) { return level }
        }
        return nil
    }

    /// The options a value sets on a runtime, to put in a form.
    static func options(_ field: AutoField, _ level: String, runtimeID: String, mappings: AutoMappings) -> [String: JSONValue] {
        mappings.cell(runtimeID, field, level)?.native?.options ?? [:]
    }
}
