import Foundation

/// Something an agent asked the app to do, and what we did about it.
///
/// On the record because the point of serving these at all is that the user can see
/// what an agent touched at the moment it touched it.
public struct ServedRequest: Codable, Hashable, Sendable {
    public var kind: Kind
    public var outcome: Outcome

    public enum Kind: Codable, Hashable, Sendable {
        case readFile(path: String)
        case writeFile(path: String, byteCount: Int)
        case runCommand(command: String, args: [String])
    }

    public enum Outcome: Codable, Hashable, Sendable {
        case served
        case refused(reason: String)
        case failed(message: String)
    }

    public init(kind: Kind, outcome: Outcome) {
        self.kind = kind
        self.outcome = outcome
    }

    /// Whether the chat says nothing about this. A read that went through changes
    /// nothing, so the page has nothing to say about it; anything that changed
    /// something, or went wrong, is said.
    public var isQuiet: Bool {
        if case .readFile = kind, case .served = outcome { return true }
        return false
    }

    /// One line, for the transcript.
    public var summary: String {
        switch kind {
        case .readFile(let path): return "Read \(Self.name(of: path))"
        case .writeFile(let path, _): return "Wrote \(Self.name(of: path))"
        case .runCommand(let command, let args):
            return ([command] + args).joined(separator: " ")
        }
    }

    private static func name(of path: String) -> String {
        URL(filePath: path).lastPathComponent
    }
}
