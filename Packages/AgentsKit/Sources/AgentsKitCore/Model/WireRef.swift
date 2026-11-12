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

    /// Reads a lineage node's ref in the form it had before #4800 (spec 2348-lineage, "Node
    /// refs"), given the node's kind, and gives the full ref. A ref in the full form already
    /// is read as `init(parsing:)` reads it. It is nil for a form it does not know; the caller
    /// keeps that one as it is. `topic` is the project of a session, a workflow or a
    /// workflow's run, which the old form did not say; it can be empty. The same rows as Go's
    /// `wire.RefFromLineage`:
    ///
    ///     issue        github:alexec/agents#123            github:issue:alexec/agents#123
    ///     pr           gitlab:group/repo!45                gitlab:mr:group/repo#45
    ///     issue        linear:ENG-4                        linear:issue:eng#ENG-4
    ///     session      session:<id>                        agents:session:<topic>#<id>
    ///     release      github:alexec/agents/release/v1.2   github:release:alexec/agents#v1.2
    ///     doc          github:alexec/agents/doc/specs/a.md github:doc:alexec/agents#specs/a.md
    ///     doc          file:/Users/me/a.md                 file:doc:#/Users/me/a.md
    ///     doc          https://www.notion.so/Page-1        web:doc:www.notion.so#/Page-1
    ///     ci-run       github:alexec/agents/actions/run/9  github:run:alexec/agents#9
    ///     deploy       testflight:com.example.app/42       testflight:deploy:com.example.app#42
    ///     target       target:testflight:com.Example.App   testflight:target:#com.example.app
    ///     health       sentry:acme/12345                   sentry:issue:acme#12345
    ///     health       betterstack:987                     betterstack:incident:#987
    ///     workflow     workflow:<folder>/<name>            agents:workflow:<topic>#<folder>/<name>
    ///     workflow-run run:<id>                            agents:workflow-run:<topic>#<id>
    ///     repo         github:alexec/agents                github:repo:#alexec/agents
    public init?(lineageKind kind: String, ref old: String, topic: String = "") {
        if let r = try? WireRef(parsing: old) {
            self = r
            return
        }
        guard let colon = old.firstIndex(of: ":") else { return nil }
        let scheme = String(old[..<colon])
        let rest = String(old[old.index(after: colon)...])
        guard !rest.isEmpty, Self.isWord(scheme) else { return nil }
        let project = topic.lowercased()
        let r: WireRef
        switch kind {
        case "session" where scheme == "session":
            r = WireRef(provider: "agents", type: "session", topic: project, id: rest)
        case "workflow" where scheme == "workflow":
            r = WireRef(provider: "agents", type: "workflow", topic: project, id: rest)
        case "workflow-run" where scheme == "run":
            r = WireRef(provider: "agents", type: "workflow-run", topic: project, id: rest)
        case "issue" where scheme == "linear" || scheme == "jira":
            guard let dash = rest.firstIndex(of: "-"), dash > rest.startIndex else { return nil }
            r = WireRef(provider: scheme, type: "issue", topic: rest[..<dash].lowercased(), id: rest)
        case "pr" where scheme == "gitlab" && rest.contains("!"):
            guard let bang = rest.lastIndex(of: "!") else { return nil }
            r = WireRef(
                provider: scheme, type: "mr", topic: rest[..<bang].lowercased(),
                id: String(rest[rest.index(after: bang)...]))
        case "issue", "pr":
            guard let hash = rest.lastIndex(of: "#") else { return nil }
            r = WireRef(
                provider: scheme, type: kind == "pr" ? Self.pullType(scheme) : kind,
                topic: rest[..<hash].lowercased(), id: String(rest[rest.index(after: hash)...]))
        case "release", "milestone":
            guard let cut = Self.cutLast(rest, "/\(kind)/") else { return nil }
            r = WireRef(provider: scheme, type: kind, topic: cut.before.lowercased(), id: cut.after)
        case "doc" where scheme == "file":
            r = WireRef(provider: "file", type: "doc", topic: "", id: rest)
        case "doc" where scheme == "https" || scheme == "http":
            let tail = rest.hasPrefix("//") ? String(rest.dropFirst(2)) : rest
            let host: String
            let path: String
            if let slash = tail.firstIndex(of: "/") {
                host = String(tail[..<slash])
                path = String(tail[tail.index(after: slash)...])
            } else {
                host = tail
                path = ""
            }
            guard !host.isEmpty else { return nil }
            r = WireRef(provider: "web", type: "doc", topic: host.lowercased(), id: "/" + path)
        case "doc":
            guard let mark = rest.range(of: "/doc/") else { return nil }
            r = WireRef(
                provider: scheme, type: "doc", topic: rest[..<mark.lowerBound].lowercased(),
                id: String(rest[mark.upperBound...]))
        case "ci-run":
            guard let cut = ["/actions/run/", "/pipelines/", "/builds/"].lazy.compactMap({ Self.cutLast(rest, $0) }).first
            else { return nil }
            r = WireRef(provider: scheme, type: "run", topic: cut.before.lowercased(), id: cut.after)
        case "deploy":
            guard let slash = rest.lastIndex(of: "/"), slash > rest.startIndex else { return nil }
            r = WireRef(
                provider: scheme, type: "deploy", topic: rest[..<slash].lowercased(),
                id: String(rest[rest.index(after: slash)...]))
        case "target" where scheme == "target":
            guard let c = rest.firstIndex(of: ":") else { return nil }
            r = WireRef(
                provider: String(rest[..<c]), type: "target", topic: "",
                id: rest[rest.index(after: c)...].lowercased())
        case "health" where scheme == "sentry":
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            r = WireRef(
                provider: scheme, type: "issue", topic: rest[..<slash].lowercased(),
                id: String(rest[rest.index(after: slash)...]))
        case "health":
            r = WireRef(provider: scheme, type: "incident", topic: "", id: rest)
        case "repo" where !rest.contains("#"):
            r = WireRef(provider: scheme, type: "repo", topic: "", id: rest.lowercased())
        default:
            return nil
        }
        guard r.check() == nil else { return nil }
        self = r
    }

    /// A lineage ref's full form, or the ref as it is when `init(lineageKind:ref:topic:)`
    /// does not know its form.
    public static func lineage(kind: String, ref: String, topic: String = "") -> String {
        WireRef(lineageKind: kind, ref: ref, topic: topic)?.description ?? ref
    }

    /// The session id in a session's ref, in the full form (`agents:session:<topic>#<id>`)
    /// or the old form (`session:<id>`). Nil for a ref that names no session.
    public static func sessionID(fromRef ref: String) -> String? {
        guard let r = WireRef(lineageKind: "session", ref: ref), r.provider == "agents", r.type == "session" else {
            return nil
        }
        return r.id
    }

    /// The ref of a session, as a query names it: the project is not known here, so the topic
    /// is empty. The daemon names the node as it keeps it; compare sessions by id.
    public static func sessionRef(id: String) -> String { "agents:session:#\(id)" }

    /// A repository's ref in either form (`github:repo:#alexec/agents` or the old
    /// `github:alexec/agents`). Nil for a text that names no repository.
    public init?(repo: String) {
        guard let r = WireRef(lineageKind: "repo", ref: repo), r.type == "repo" else { return nil }
        self = r
    }

    /// For a repository's ref: the old form, `<provider>:<id>` (`github:alexec/agents`,
    /// `linear:eng`), which the parts of the app that show a repository still read.
    public var repoShortForm: String { "\(provider):\(id)" }

    /// A lineage ref with no kind, in either form: the full form, or the old form of a release
    /// (`…/release/<tag>`), a GitLab merge request (`!`), a session or an issue.
    public init?(anyLineage ref: String) {
        if let r = try? WireRef(parsing: ref) {
            self = r
            return
        }
        let kind =
            ref.hasPrefix("session:") ? "session"
            : ref.contains("/release/") ? "release"
            : ref.hasPrefix("gitlab:") && ref.contains("!") ? "pr" : "issue"
        guard let r = WireRef(lineageKind: kind, ref: ref) else { return nil }
        self = r
    }

    /// The ref of the repo or tracker this ref is in (#4800): `github:repo:#alexec/agents` of
    /// `github:issue:alexec/agents#12`; nil for a ref with no topic.
    public var repoRef: WireRef? {
        if type == "repo" { return self }
        guard !topic.isEmpty else { return nil }
        return WireRef(provider: provider, type: "repo", topic: "", id: topic)
    }

    /// The old lineage form of a ref (before #4800), which some words and addresses are made
    /// from: `github:alexec/agents#12` of `github:issue:alexec/agents#12`. A ref in the old form,
    /// or one it does not know, is as it is. The same as the web page's `legacyRef`.
    public static func legacy(_ ref: String) -> String {
        guard let r = try? WireRef(parsing: ref) else { return ref }
        let (p, topic, id) = (r.provider, r.topic, r.id)
        if p == "agents" {
            switch r.type {
            case "session": return "session:\(id)"
            case "workflow": return "workflow:\(id)"
            case "workflow-run": return "run:\(id)"
            default: return ref
            }
        }
        switch r.type {
        case "issue":
            if p == "linear" || p == "jira" { return "\(p):\(id)" }
            if p == "sentry" { return "sentry:\(topic)/\(id)" }
            return "\(p):\(topic)#\(id)"
        case "pr": return "\(p):\(topic)#\(id)"
        case "mr": return "\(p):\(topic)!\(id)"
        case "release", "milestone": return "\(p):\(topic)/\(r.type)/\(id)"
        case "doc":
            if p == "file" { return "file:\(id)" }
            if p == "web" { return "https://\(topic)\(id == "/" ? "" : id)" }
            return "\(p):\(topic)/doc/\(id)"
        case "run":
            let mark = p == "gitlab" || p == "bitbucket" ? "/pipelines/" : p == "azuredevops" ? "/builds/" : "/actions/run/"
            return "\(p):\(topic)\(mark)\(id)"
        case "deploy": return "\(p):\(topic)/\(id)"
        case "target": return "target:\(p):\(id)"
        case "incident", "repo": return "\(p):\(id)"
        default: return ref
        }
    }

    /// The text before and after the last `sep` in `s`, neither of them empty.
    private static func cutLast(_ s: String, _ sep: String) -> (before: String, after: String)? {
        guard let r = s.range(of: sep, options: .backwards), r.lowerBound > s.startIndex, r.upperBound < s.endIndex
        else { return nil }
        return (before: String(s[..<r.lowerBound]), after: String(s[r.upperBound...]))
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
