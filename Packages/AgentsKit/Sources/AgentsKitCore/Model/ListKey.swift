import Foundation

/// The session list's single keys (#4796, spec `specs/4777-fast/spec.md`, pattern 4), as Linear
/// has them: j and k to the next and the previous session, e to archive it, l to put its request
/// in Later, r to rename it. Only while the list has the keyboard, so a field never takes them,
/// and with no modifier. The Mac window and the Remote use this table; the web page's
/// `Web/src/model/listKeys.ts` is the same.
public enum ListKey: Character, CaseIterable, Sendable {
    case next = "j"
    case previous = "k"
    case archive = "e"
    case later = "l"
    case rename = "r"

    /// The key for what was typed, with no modifier held; nil for any other key.
    public init?(typed: String, modified: Bool) {
        guard !modified, typed.count == 1, let key = ListKey(rawValue: Character(typed)) else { return nil }
        self = key
    }

    /// As a menu shows it: `E`.
    public var glyph: String { String(rawValue).uppercased() }

    /// Every key, for a handler that takes a set of characters.
    public static let characters = String(allCases.map(\.rawValue))

    /// The time `l` puts a request in Later for: the first of Later's times. Later again, from
    /// the row's menu, moves it.
    public static let laterTime: NeedRequest.Later = .hour

    /// Later's item in a menu, with the key's time: "Later in 1 Hour".
    public static var laterWord: String { "Later \(laterTime.word.prefix(1).lowercased())\(laterTime.word.dropFirst())" }

    /// The session j or k goes to, from `current`, in the list's order. It stops at the ends;
    /// with nothing open, j goes to the first and k to the last.
    public static func step(from current: UUID?, in ids: [UUID], forward: Bool) -> UUID? {
        guard let current, let at = ids.firstIndex(of: current) else { return forward ? ids.first : ids.last }
        let next = at + (forward ? 1 : -1)
        return ids.indices.contains(next) ? ids[next] : nil
    }

    /// The session to open after e archives `archived`: the next one, or the one before it at
    /// the end, so the person stays in the list; nil when it was the only one.
    public static func after(archiving archived: UUID, in ids: [UUID]) -> UUID? {
        guard let at = ids.firstIndex(of: archived) else { return nil }
        if ids.indices.contains(at + 1) { return ids[at + 1] }
        return at > 0 ? ids[at - 1] : nil
    }
}
