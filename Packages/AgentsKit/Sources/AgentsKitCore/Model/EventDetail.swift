import Foundation

/// One detail a kind of event carries, as the catalogue describes it (073): whether it
/// is a set, which values it can have, what older builds wrote in their place, and how
/// a trigger's summary says a filter on it.
///
/// What lets `parse` refuse `outcome: complete` with the values that would have been
/// right, rather than accept a filter that never matches.
public struct EventDetail: Hashable, Sendable {
    /// Where a detail's values come from.
    public enum Values: Hashable, Sendable {
        /// Anything: labels, ids, branch names, a custom event's details.
        case open
        /// Exactly these codes.
        case fixed([String])
        /// The runtimes this version knows, read when asked, since a test may add one.
        case runtimes
    }

    /// How a summary says a filter on this detail (073 FR-022).
    public enum Wording: Hashable, Sendable {
        /// "workflow nightly", "branch main or develop"
        case plain
        /// "labelled bug or regression"
        case labelled
        /// "on Claude or Grok"
        case runtime
        /// "done or nothing to do": the code, with `_` read as a space.
        case spaced
        /// "and parked", "and not parked"
        case afterwards
        /// "started by a workflow or another agent"
        case startedBy
        /// Each code's own words, joined with "or".
        case codes([String: String])
    }

    /// An older build's words for a code: the whole of them, or their fixed part when
    /// the rest varied (a chain's depth, a workflow's name).
    public enum OldWords: Hashable, Sendable {
        case exactly(String, code: String)
        case starting(String, code: String)
        case ending(String, code: String)

        /// `given` is lowercased already; the words are lowercased here.
        func code(for given: String) -> String? {
            switch self {
            case .exactly(let words, let code): return given == words.lowercased() ? code : nil
            case .starting(let words, let code): return given.hasPrefix(words.lowercased()) ? code : nil
            case .ending(let words, let code): return given.hasSuffix(words.lowercased()) ? code : nil
            }
        }
    }

    public var key: String
    /// The event carries members, comma-joined, and a filter value means "has it".
    public var isSet: Bool
    /// About the agent rather than the event (`labels`, `runtime`, `started_by`): left
    /// out of Copy as trigger, so a copied trigger fires for events like the one copied
    /// rather than only for agents like it (073 FR-025).
    public var isContext: Bool
    public var source: Values
    public var oldWords: [OldWords]
    public var wording: Wording

    public init(_ key: String, isSet: Bool = false, isContext: Bool = false, values: Values = .open,
                oldWords: [OldWords] = [], wording: Wording = .plain) {
        self.key = key
        self.isSet = isSet
        self.isContext = isContext
        self.source = values
        self.oldWords = oldWords
        self.wording = wording
    }

    /// The values it can have, or `nil` when any value will do.
    public var values: [String]? {
        switch source {
        case .open: return nil
        case .fixed(let values): return values
        case .runtimes: return RuntimeCatalog.builtIn.map(\.id)
        }
    }

    /// The code an older build's words stand for, if they stand for one.
    public func code(forOldWords given: String) -> String? {
        let lowered = given.lowercased()
        for words in oldWords {
            if let code = words.code(for: lowered) { return code }
        }
        return nil
    }

    /// A filter on this detail, in the words a trigger's summary uses.
    public func words(_ values: [String]) -> String {
        func or(_ parts: [String]) -> String { parts.joined(separator: " or ") }
        switch wording {
        case .plain: return "\(key) \(or(values))"
        case .labelled: return "labelled \(or(values))"
        case .runtime: return "on \(or(values.map(PoolWords.runtimeName)))"
        case .spaced: return or(values.map { $0.replacingOccurrences(of: "_", with: " ") })
        case .afterwards:
            if Set(values) == ["park", "stay"] { return "and parked or not" }
            return values.first == "stay" ? "and not parked" : "and parked"
        case .startedBy:
            let who = ["person": "you", "workflow": "a workflow", "agent": "another agent"]
            return "started by \(or(values.map { who[$0] ?? $0 }))"
        case .codes(let words):
            return or(values.map { words[$0] ?? $0 })
        }
    }
}
