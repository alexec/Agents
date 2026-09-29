import Foundation

/// Editing Matching models (052, US6). Every change keeps FR-032: a model sits in one
/// level at most for its runtime, so putting it in a level takes it out of any other.
extension PoolSettings {
    /// Put `cell` in `levelID`'s column for `runtimeID`, moving the same model out of any
    /// other level for that runtime. Nil clears the cell.
    public func placing(_ cell: Cell?, for runtimeID: String, in levelID: UUID) -> PoolSettings {
        var next = self
        if let cell {
            for index in next.levels.indices where next.levels[index].id != levelID
                && next.levels[index].cells[runtimeID]?.model == cell.model {
                next.levels[index].cells[runtimeID] = nil
            }
        }
        if let index = next.levels.firstIndex(where: { $0.id == levelID }) {
            next.levels[index].cells[runtimeID] = cell
        }
        return next
    }

    /// A new, empty level, named as asked or "Level n" when no name is given.
    public func addingLevel(named name: String? = nil) -> (pool: PoolSettings, levelID: UUID) {
        var next = self
        let trimmed = name?.trimmingCharacters(in: .whitespaces) ?? ""
        let level = Level(name: trimmed.isEmpty ? "Level \(levels.count + 1)" : trimmed)
        next.levels.append(level)
        return (next, level.id)
    }

    /// Remember a pair the person chose (Continue with's **Remember**): the model the
    /// chat had beside the model it carried on with. It goes in the level that already
    /// holds the chat's model, else in `levelID`, else in a new level `newLevelName`.
    public func remembering(from: (runtimeID: String, cell: Cell), to: (runtimeID: String, cell: Cell),
                            levelID: UUID? = nil, newLevelName: String? = nil) -> PoolSettings {
        var pool = self
        let target: UUID
        if let holding = levels.first(where: { $0.cells[from.runtimeID]?.model == from.cell.model }) {
            target = holding.id
        } else if let levelID, levels.contains(where: { $0.id == levelID }) {
            target = levelID
        } else {
            let added = pool.addingLevel(named: newLevelName)
            pool = added.pool
            target = added.levelID
        }
        return pool.placing(from.cell, for: from.runtimeID, in: target).placing(to.cell, for: to.runtimeID, in: target)
    }

    /// A cell whose model its runtime no longer offers: drawn struck through, and treated
    /// as empty when a chat switches.
    public static func isGone(_ cell: Cell, offered options: [ConfigOption]) -> Bool {
        guard let model = SettingsCarry.model(in: options), let choices = model.options else { return false }
        return !choices.contains { $0.value == cell.model }
    }
}
