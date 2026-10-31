import AgentsKitCore
import SwiftUI

/// The Model or Permission mode pill, in the words every runtime shares (#2658): the value
/// alone (**Balanced**, **Ask**), or **Custom** when the runtime's own setting matches none.
///
/// The menu's header names the field; each value says what it is on the runtime ("Sonnet 5
/// on Claude"). The runtime's own choices stay behind **⋯ <runtime>'s own**, which is not
/// there on Auto: Auto has no runtime yet. Bypass Permissions asks once more before it is
/// set, as Yes to all does (#2892): it lets the agent change things outside its folder.
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

    @State private var isConfirming = false

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
                        if LevelWords.asksFirst(field, level), level != chosen {
                            isConfirming = true
                        } else {
                            choose(level)
                        }
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
        // A dialog, not a second step in the menu: a Menu closes when an item is chosen.
        .confirmationDialog(LevelWords.bypassConfirmTitle, isPresented: $isConfirming, titleVisibility: .visible) {
            Button(LevelWords.bypassConfirmButton, role: .destructive) { choose(PermissionLevel.bypassPermissions.rawValue) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LevelWords.bypassConfirmMessage)
        }
    }

    /// "Sonnet 5 on Claude", or why the runtime cannot give it. A value the runtime gives
    /// only by a safer one says so: "Default on Codex · nearest safer: …" (#2893).
    private func line(_ level: String, _ cell: AutoMapping?) -> String? {
        guard let cell else { return nil }
        let on = runtimeName.map { " on \($0)" } ?? ""
        switch cell.mark {
        case .notPossible, .dropped:
            return [LevelWords.mark(cell.mark), cell.note].compactMap { $0 }.joined(separator: ": ")
        case .nearestSafer:
            return cell.words + on + " · " + (cell.note ?? LevelWords.mark(cell.mark))
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
    /// `preferring` is the value the person chose, tried first: two values can set the same
    /// options (Bypass Permissions, nearest safer, is Approve for me on Codex), and the
    /// person's choice must stay ticked (#2893).
    static func level(_ field: AutoField, runtimeID: String, mappings: AutoMappings, preferring: String? = nil,
                      value: (String) -> JSONValue?) -> String? {
        // The more particular first: Fast and Smart set a model; Balanced may set none.
        var order: [String] = field == .model ? ["fast", "smart", "balanced"] : LevelWords.levels(field)
        if let preferring, let i = order.firstIndex(of: preferring) { order.insert(order.remove(at: i), at: 0) }
        for level in order {
            guard let cell = mappings.cell(runtimeID, field, level), let options = cell.native?.options,
                  cell.mark != .notPossible else { continue }
            if options.isEmpty { continue }
            if options.allSatisfy({ value($0.key) == $0.value }) { return level }
        }
        return nil
    }
}
