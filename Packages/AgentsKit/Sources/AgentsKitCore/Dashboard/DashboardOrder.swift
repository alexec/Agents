import Foundation

/// Where a person or an agent has put the tiles (#147): sections in order, each with its
/// tiles in order. The project's `.agents/dashboard/_order.json`, written only by the host.
///
/// A tile listed here is shown where it is listed, whatever its file's `section` says, so a
/// person's drag is not undone by its keeper setting it again. A tile not listed goes after
/// the listed ones, in its file's section, in made order; a section not listed goes after
/// the listed ones. So a new tile lands at the end, and a project with no order shows as
/// it always did.
public struct DashboardOrder: Codable, Sendable, Hashable {
    public typealias Section = DashboardOrderSection

    public var sections: [DashboardOrderSection]

    public init(sections: [Section] = []) {
        self.sections = sections
    }

    /// The file's name in `.agents/dashboard/`. Tile ids never start with `_`.
    public static let fileName = "_order.json"

    public var isEmpty: Bool { sections.allSatisfy { $0.tiles.isEmpty } }

    /// Every tile id listed, in order.
    public var tiles: [String] { sections.flatMap(\.tiles) }

    /// Each tile once, in the first place it is listed; a heading once, its tiles gathered
    /// under its first appearance; sections with no tiles left out; only ids in `known`
    /// when given. What the host keeps, whatever a client sent.
    public func cleaned(known: Set<String>? = nil) -> DashboardOrder {
        var seen = Set<String>()
        var out: [Section] = []
        for section in sections {
            let title = section.title.flatMap { $0.isEmpty ? nil : $0 }
            let tiles = section.tiles.filter { id in
                (known?.contains(id) ?? true) && seen.insert(id).inserted
            }
            if let index = out.firstIndex(where: { $0.title == title }) {
                out[index].tiles += tiles
            } else {
                out.append(Section(title: title, tiles: tiles))
            }
        }
        return DashboardOrder(sections: out.filter { !$0.tiles.isEmpty })
    }

    /// `ids` taken out of wherever they are and put in `section`, before `before` (a tile
    /// id in that section) or at its end. A section not there yet is added at the end.
    public func moving(_ ids: [String], to section: String?, before: String? = nil) -> DashboardOrder {
        let moving = Set(ids)
        var sections = self.sections.map { Section(title: $0.title, tiles: $0.tiles.filter { !moving.contains($0) }) }
        let index: Int
        if let found = sections.firstIndex(where: { $0.title == section }) {
            index = found
        } else {
            sections.append(Section(title: section, tiles: []))
            index = sections.count - 1
        }
        let at = before.flatMap { sections[index].tiles.firstIndex(of: $0) } ?? sections[index].tiles.endIndex
        sections[index].tiles.insert(contentsOf: ids, at: at)
        return DashboardOrder(sections: sections).cleaned()
    }

    /// `ids` put after `after` (a tile id), in its section.
    public func moving(_ ids: [String], after: String) -> DashboardOrder {
        guard let section = sections.first(where: { $0.tiles.contains(after) }) else { return self }
        let rest = section.tiles.filter { !ids.contains($0) }
        guard let at = rest.firstIndex(of: after) else { return self }
        let next = rest.index(after: at) < rest.endIndex ? rest[rest.index(after: at)] : nil
        return moving(ids, to: section.title, before: next)
    }

    /// The section headed `title` put before the one headed `before`, or last.
    public func movingSection(_ title: String?, before: String??) -> DashboardOrder {
        guard let found = sections.firstIndex(where: { $0.title == title }) else { return self }
        var sections = self.sections
        let section = sections.remove(at: found)
        let at = before.flatMap { target in sections.firstIndex(where: { $0.title == target }) } ?? sections.endIndex
        sections.insert(section, at: at)
        return DashboardOrder(sections: sections)
    }
}

/// One section of the order: its heading, and its tiles in order.
public struct DashboardOrderSection: Codable, Sendable, Hashable {
    /// Nil for the tiles under no heading.
    public var title: String?
    public var tiles: [String]

    public init(title: String?, tiles: [String]) {
        self.title = title
        self.tiles = tiles
    }
}

public extension DashboardModel {
    /// The whole order as shown, hidden tiles included: what a client edits and sends back
    /// with `dashboard/arrange`, so every tile has its place once a person has moved one.
    static func arrangement(_ snapshot: DashboardSnapshot) -> DashboardOrder {
        DashboardOrder(sections: sections(snapshot, includeHidden: true).map {
            DashboardOrder.Section(title: $0.title, tiles: $0.tiles.map(\.id))
        })
    }

    /// The tile shown just before `id` in its section, or after it: what Move Up and Move
    /// Down step past. Nil at either end.
    static func neighbour(of id: String, in sections: [(title: String?, tiles: [TileView])], step: Int) -> String? {
        for section in sections {
            guard let at = section.tiles.firstIndex(where: { $0.id == id }) else { continue }
            let to = at + step
            return section.tiles.indices.contains(to) ? section.tiles[to].id : nil
        }
        return nil
    }

    /// Move Up (-1) or Move Down (+1), from the sections as shown.
    static func stepping(_ id: String, by step: Int, in snapshot: DashboardSnapshot,
                         includeHidden: Bool) -> DashboardOrder? {
        let shown = sections(snapshot, includeHidden: includeHidden)
        guard let next = neighbour(of: id, in: shown, step: step) else { return nil }
        let order = arrangement(snapshot)
        return step < 0 ? order.moving([id], to: order.sections.first { $0.tiles.contains(next) }?.title, before: next)
                        : order.moving([id], after: next)
    }
}
