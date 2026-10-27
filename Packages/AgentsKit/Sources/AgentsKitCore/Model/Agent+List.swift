import Foundation

/// A list of agents read one at a time (#2650): a record this build cannot read (a
/// worktree with `"folder": ""`, left by #2617) is left out and said in the wire log, and
/// the rest are listed. Only a value that is not a list fails. `agents/list` answers are
/// read this way (`DaemonClient.call`), and so is the catch-up's page of agents.
@propertyWrapper
public struct AgentRows: Codable, Sendable {
    public var wrappedValue: [Agent]

    public init(wrappedValue: [Agent]) { self.wrappedValue = wrappedValue }

    public init(from decoder: Decoder) throws {
        var rows = try decoder.unkeyedContainer()
        var agents: [Agent] = []
        while !rows.isAtEnd {
            let index = rows.currentIndex
            let row = try rows.decode(Row.self)
            switch row.agent {
            case .success(let agent): agents.append(agent)
            case .failure(let error):
                WireLog.write("left out agent [\(index)] \(row.id ?? "with no id"), which did not decode: \(error)")
            }
        }
        wrappedValue = agents
    }

    public func encode(to encoder: Encoder) throws { try wrappedValue.encode(to: encoder) }

    private struct Row: Decodable {
        let agent: Result<Agent, Error>
        let id: String?

        private enum Keys: String, CodingKey { case id }

        init(from decoder: Decoder) throws {
            agent = Result { try Agent(from: decoder) }
            id = try? decoder.container(keyedBy: Keys.self).decodeIfPresent(String.self, forKey: .id)
        }
    }
}

extension Agent {
    /// An `agents/list` answer, read as `AgentRows` reads one.
    public static func list(_ value: JSONValue) throws -> [Agent] {
        try value.decode(AgentRows.self).wrappedValue
    }
}
