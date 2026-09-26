import Foundation

/// What a chat's settings become on another runtime, and where each came from (052,
/// FR-015; the Continue with sheet's four columns).
public struct CarryPlan: Hashable, Sendable {
    /// The values to set on the new runtime, keyed by its option id.
    public var values: [String: JSONValue]
    /// One per option the new runtime offers, in its order: now, next and where from.
    public var rows: [CarriedSetting]
    public var dropped: [Dropped]

    public init(values: [String: JSONValue] = [:], rows: [CarriedSetting] = [], dropped: [Dropped] = []) {
        self.values = values
        self.rows = rows
        self.dropped = dropped
    }
}

/// The FR-015 rules, pure.
public enum SettingsCarry {
    public struct Side: Sendable {
        public var runtimeID: String
        /// What the runtime offers. Empty when it is not known yet.
        public var options: [ConfigOption]
        /// The values in force, keyed by option id.
        public var values: [String: JSONValue]

        public init(runtimeID: String, options: [ConfigOption], values: [String: JSONValue] = [:]) {
            self.runtimeID = runtimeID
            self.options = options
            self.values = values
        }

        func value(of option: ConfigOption) -> JSONValue? { values[option.id] ?? option.currentValue }
    }

    public static func plan(from: Side, to: Side, levels: [Level] = [], entryModel: JSONValue? = nil,
                            remembered: JSONValue? = nil, extraArguments: [String] = [],
                            alwaysAllowCount: Int = 0, queuedCommands: [String] = []) -> CarryPlan {
        var plan = CarryPlan()
        let fromModel = model(in: from.options).flatMap(from.value(of:))
        let level = fromModel.flatMap { current in
            levels.first { $0.cells[from.runtimeID]?.model == current && $0.cells[to.runtimeID] != nil }
        }
        let levelCell = level.flatMap { $0.cells[to.runtimeID] }

        for option in to.options where option.isRenderable {
            let previous = counterpart(of: option, in: from.options)
            let now = previous.flatMap(from.value(of:))
            var chosen: JSONValue?
            var source: CarriedSetting.Source = .runtimeDefault

            if option.id == ModeMemory.modeOption(in: to.options)?.id {
                (chosen, source) = mode(from: now, offered: option)
            } else if isModel(option) {
                if let cell = levelCell, offers(option, cell.model) {
                    (chosen, source) = (cell.model, .level(level!.name))
                } else if let entryModel, offers(option, entryModel) {
                    (chosen, source) = (entryModel, .poolEntry)
                } else if let remembered, offers(option, remembered) {
                    (chosen, source) = (remembered, .remembered)
                }
            } else if let cell = levelCell, let effort = cell.effort,
                      cell.effortOptionID.map({ $0 == option.id }) ?? (option.category == "thought_level"),
                      offers(option, effort) {
                (chosen, source) = (effort, .level(level!.name))
            } else if let now, offers(option, now) {
                (chosen, source) = (now, .sameValue)
            }
            if let chosen { plan.values[option.id] = chosen }
            plan.rows.append(CarriedSetting(optionID: option.id, name: option.name, from: now,
                                            to: chosen ?? option.currentValue, source: source))
        }
        if !extraArguments.isEmpty { plan.dropped.append(.extraArguments(extraArguments)) }
        if alwaysAllowCount > 0 { plan.dropped.append(.alwaysAllow(count: alwaysAllowCount)) }
        plan.dropped += queuedCommands.map(Dropped.queuedSlashCommand)
        return plan
    }

    /// The new runtime's loosest mode that is no looser than the chat's; the strictest it
    /// has when the chat's mode has no place on the scale (FR-015, FR-027).
    static func mode(from current: JSONValue?, offered option: ConfigOption) -> (JSONValue?, CarriedSetting.Source) {
        let choices = option.options ?? []
        let ranked = choices.compactMap { choice -> (JSONValue, Int)? in
            guard let name = choice.value.stringValue, let rank = ModeLooseness.rank(name) else { return nil }
            return (choice.value, rank)
        }
        guard !ranked.isEmpty else { return (nil, .runtimeDefault) }
        if let name = current?.stringValue, let limit = ModeLooseness.rank(name) {
            if let exact = ranked.first(where: { $0.0 == current }) { return (exact.0, .sameValue) }
            if let best = ranked.filter({ $0.1 <= limit }).max(by: { $0.1 < $1.1 }) {
                return (best.0, .closestNoLooser)
            }
        }
        return (ranked.min { $0.1 < $1.1 }!.0, .strictestMode)
    }

    static func isModel(_ option: ConfigOption) -> Bool { option.category == "model" || option.id == "model" }

    public static func model(in options: [ConfigOption]) -> ConfigOption? { options.first(where: isModel) }

    /// The same kind of option on the other side: same id, else same category.
    static func counterpart(of option: ConfigOption, in options: [ConfigOption]) -> ConfigOption? {
        options.first { $0.id == option.id }
            ?? option.category.flatMap { category in options.first { $0.category == category } }
    }

    static func offers(_ option: ConfigOption, _ value: JSONValue) -> Bool {
        guard let choices = option.options else { return option.isBoolean }
        return choices.contains { $0.value == value }
    }
}
