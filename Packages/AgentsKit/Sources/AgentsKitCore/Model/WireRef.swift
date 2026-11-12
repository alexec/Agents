import Foundation

/// A ref (#4727, spec 4724-event-bus, "A ref"): one thing as `provider:type:topic#id`, such as
/// `github:pr:alexec/agents#4702` or `agents:machine:#mac-mini`. Provider, type and topic are
/// lower case; the first `#` ends the topic, and the id keeps its case and can hold `#` and
/// `/`. The schema's `Ref` (`x-swift-type`); the same parser as Go's `wire.Ref` and the web
/// page's `protocol/ref.ts`. On the wire it is its full form, as `description` writes it.
public struct WireRef: Codable, Sendable, Hashable, CustomStringConvertible {
    public var provider: String
    public var type: String
    public var topic: String
    public var id: String

    /// The longest ref's text, so one line that holds one stays small.
    public static let maxLength = 512

    /// What a short form leaves out: the folder's origin and the forge's answer.
    public struct Context: Sendable {
        /// The folder's origin, such as `github` and `alexec/agents`.
        public var provider: String?
        public var topic: String?
        /// The forge's answer for a number whose form does not say its type (`pr`, `issue`).
        public var typeOf: (@Sendable (_ provider: String, _ topic: String, _ id: String) -> String?)?

        public init(
            provider: String? = nil, topic: String? = nil,
            typeOf: (@Sendable (_ provider: String, _ topic: String, _ id: String) -> String?)? = nil
        ) {
            self.provider = provider
            self.topic = topic
            self.typeOf = typeOf
        }
    }

    public enum ParseError: Error, Equatable, Sendable {
        case notARef(String)
        case wrong(String)
        case noOrigin
        case noType(String)
    }

    /// A ref from its parts, as they are: `check()` says whether they make a ref.
    public init(provider: String, type: String, topic: String, id: String) {
        self.provider = provider
        self.type = type
        self.topic = topic
        self.id = id
    }

    /// Reads the full form, lowering the case of provider, type and topic.
    public init(parsing s: String) throws {
        guard s.utf8.count <= Self.maxLength else { throw ParseError.wrong("longer than \(Self.maxLength) bytes") }
        guard let hash = s.firstIndex(of: "#") else { throw ParseError.notARef(s) }
        let parts = s[..<hash].split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw ParseError.notARef(s) }
        self.init(
            provider: parts[0].lowercased(), type: parts[1].lowercased(), topic: parts[2].lowercased(),
            id: String(s[s.index(after: hash)...]))
        if let wrong = check() { throw ParseError.wrong(wrong) }
    }

    /// Reads a ref as a person types it and gives the full ref: the full form, `#123` and
    /// `P#123` (the origin's topic), `owner/repo#123` (the origin's provider) and lineage's
    /// `github:owner/repo#123`. The forge says the type when the form does not.
    public init(short input: String, context c: Context = Context()) throws {
        let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.utf8.count <= Self.maxLength else { throw ParseError.wrong("longer than \(Self.maxLength) bytes") }
        guard let hash = s.firstIndex(of: "#"), s.index(after: hash) < s.endIndex else { throw ParseError.notARef(s) }
        let head = String(s[..<hash])
        let id = String(s[s.index(after: hash)...])
        var provider: String
        var topic: String
        var type: String?
        switch head.filter({ $0 == ":" }).count {
        case 2:
            try self.init(parsing: s)
            return
        case 1:
            let parts = head.split(separator: ":", omittingEmptySubsequences: false)
            provider = String(parts[0])
            topic = String(parts[1])
        default:
            if head.isEmpty || head.uppercased() == "P" {
                guard let p = c.provider, !p.isEmpty, let t = c.topic, !t.isEmpty else { throw ParseError.noOrigin }
                provider = p
                topic = t
                if !head.isEmpty { type = Self.pullType(provider) }
            } else if head.contains("/") {
                guard let p = c.provider, !p.isEmpty else { throw ParseError.noOrigin }
                provider = p
                topic = head
            } else {
                throw ParseError.notARef(s)
            }
        }
        provider = provider.lowercased()
        topic = topic.lowercased()
        if type == nil {
            guard let t = c.typeOf?(provider, topic, id), !t.isEmpty else {
                throw ParseError.noType("\(provider):\(topic)#\(id)")
            }
            type = t
        }
        self.init(provider: provider, type: (type ?? "").lowercased(), topic: topic, id: id)
        if let wrong = check() { throw ParseError.wrong(wrong) }
    }

    /// A provider's type for a pull request: `mr` on GitLab, `pr` elsewhere.
    public static func pullType(_ provider: String) -> String {
        provider.lowercased() == "gitlab" ? "mr" : "pr"
    }

    /// Says what is wrong with the ref's parts, or nil.
    public func check() -> String? {
        if !Self.isWord(provider) { return "provider \"\(provider)\": want lower case letters, digits and -" }
        if !Self.isWord(type) { return "type \"\(type)\": want lower case letters, digits and -" }
        if topic.contains(":") || topic.contains("#") { return "topic \"\(topic)\": holds : or #" }
        if topic != topic.lowercased() { return "topic \"\(topic)\": want lower case" }
        if id.isEmpty { return "no id after #" }
        if description.utf8.count > Self.maxLength { return "longer than \(Self.maxLength) bytes" }
        return nil
    }

    /// The full form, `provider:type:topic#id`.
    public var description: String { "\(provider):\(type):\(topic)#\(id)" }

    private static func isWord(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        do {
            try self.init(parsing: s)
        } catch {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not a ref in the full form: \(s)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
