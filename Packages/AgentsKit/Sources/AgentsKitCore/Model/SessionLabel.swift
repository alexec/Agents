import Foundation

/// One folder-scoped name attached to a session. The owner is the person or the
/// agent represented by the containing session.
public struct SessionLabel: Codable, Hashable, Sendable {
    public enum Owner: String, Codable, Hashable, Sendable {
        case person
        case agent
    }

    public var value: String
    public var owner: Owner
    public var addedAt: Date

    public var normalizedValue: String { SessionLabelPolicy.key(value) }

    /// What a label names, by its text alone, so a chip can be coloured by it (#2958).
    /// No tracker is asked: `#12` is an issue and `P#12` a pull request whatever they hold.
    public enum Kind: String, Codable, Hashable, Sendable {
        /// `#123`, or a tracker key such as `ENG-4`: the labels that link a session to an issue.
        case issue
        /// `P#123`: the label that links a session to a pull request.
        case pullRequest
        /// `merged`, `closed` or `archived`: the work is over.
        case finished
        /// Anything else.
        case plain
    }

    public var kind: Kind { Self.kind(of: value) }

    public static func kind(of value: String) -> Kind {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.wholeMatch(of: /#[0-9]+/) != nil || text.wholeMatch(of: /[A-Z][A-Z0-9]*-[0-9]+/) != nil { return .issue }
        if text.wholeMatch(of: /[Pp]#[0-9]+/) != nil { return .pullRequest }
        if ["merged", "closed", "archived"].contains(text.lowercased()) { return .finished }
        return .plain
    }

    public init(value: String, owner: Owner, addedAt: Date = Date()) {
        self.value = value
        self.owner = owner
        self.addedAt = addedAt
    }
}

/// The one label policy used before any agent record is changed. It works on copies,
/// so a refused request cannot partly alter a session.
public enum SessionLabelPolicy {
    public static let maximumCount = 5
    public static let maximumLength = 24

    public enum Refusal: Error, LocalizedError, Equatable, Sendable {
        case empty
        case tooLong
        case tooMany
        case conflictingChange(String)
        case ownedByPerson(String)

        public var errorDescription: String? {
            switch self {
            case .empty: return "A label needs at least one non-space character."
            case .tooLong: return "A label can be at most 24 characters."
            case .tooMany: return "A session can have at most five labels."
            case .conflictingChange(let value):
                return "The label \(value) cannot be added and removed in the same change."
            case .ownedByPerson(let value):
                return "The label \(value) belongs to the person, so an agent cannot change it."
            }
        }
    }

    public static func key(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func cleaned(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw Refusal.empty }
        guard result.count <= maximumLength else { throw Refusal.tooLong }
        return result
    }

    /// What a tag field holds once typed: everything before the last comma is finished
    /// labels, and what follows it is still being typed. A pasted "a, b, c" is two
    /// labels and a third in progress; Return finishes that one.
    public static func split(typed text: String) -> (finished: [String], remainder: String) {
        var pieces = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        let remainder = pieces.removeLast()
        return (pieces, remainder)
    }

    /// The typed values a session can take as they stand: cleaned, not already on it,
    /// not repeated, and only as many as there is room for, so one stray value does not
    /// have the whole change refused.
    public static func accepted(_ typed: [String], existing: [String]) -> [String] {
        var seen = Set(existing.map(key))
        var result: [String] = []
        for value in typed {
            guard existing.count + result.count < maximumCount,
                  let value = try? cleaned(value),
                  seen.insert(key(value)).inserted else { continue }
            result.append(value)
        }
        return result
    }

    /// Existing labels elsewhere in the folder carry its current canonical spelling.
    /// The caller supplies those from `vocabulary(in:agents:)`.
    public static func change(current: [SessionLabel], add: [String] = [], remove: [String] = [],
                              actor: SessionLabel.Owner, folderLabels: [SessionLabel],
                              at date: Date = Date()) throws -> [SessionLabel] {
        let adding = try add.map(cleaned)
        let removing = try remove.map(cleaned)
        let addKeys = Set(adding.map(key))
        if let conflict = removing.first(where: { addKeys.contains(key($0)) }) {
            throw Refusal.conflictingChange(conflict)
        }

        var result = current
        for value in removing {
            guard let index = result.firstIndex(where: { $0.normalizedValue == key(value) }) else { continue }
            if actor == .agent && result[index].owner == .person {
                throw Refusal.ownedByPerson(result[index].value)
            }
            result.remove(at: index)
        }
        for value in adding {
            if let index = result.firstIndex(where: { $0.normalizedValue == key(value) }) {
                if actor == .agent && result[index].owner == .person {
                    throw Refusal.ownedByPerson(result[index].value)
                }
                if actor == .person { result[index].owner = .person }
                continue
            }
            guard result.count < maximumCount else { throw Refusal.tooMany }
            let canonical = folderLabels.first(where: { $0.normalizedValue == key(value) })?.value ?? value
            result.append(SessionLabel(value: canonical, owner: actor, addedAt: date))
        }
        return result
    }

    /// Only labels still attached to a session are suggested. The daemon serializes
    /// mutations, so every new copy can reuse the spelling already in this vocabulary.
    public static func vocabulary(in folder: URL, agents: some Sequence<Agent>) -> [SessionLabel] {
        let folder = Folder.standardize(folder)
        let all = agents.filter { $0.folderPath == folder }.flatMap(\.labels)
            .sorted { left, right in
                if left.addedAt != right.addedAt { return left.addedAt < right.addedAt }
                return left.normalizedValue < right.normalizedValue
            }
        var seen: Set<String> = []
        return all.filter { seen.insert($0.normalizedValue).inserted }
    }
}
