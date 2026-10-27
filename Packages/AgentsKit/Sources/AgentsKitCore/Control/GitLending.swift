import Foundation

/// This Mac's git access, lent to a host through the control plane (#1122): the host's git
/// asks its own agentsd, which asks the control plane, which asks the lending host, once a
/// person said yes for that host and git server. The credential is used for one git
/// command and kept nowhere.
public extension DaemonAPI {
    /// `machines/lendGit`.
    struct LendGit: Codable, Sendable, Hashable {
        public var host: MachineRef
        public var from: MachineRef
        /// The git server, as git names it: `github.com`, or `git.example.com:8443`.
        public var server: String
        public var allowed: Bool
        public init(host: MachineRef, from: MachineRef, server: String, allowed: Bool) {
            self.host = host
            self.from = from
            self.server = server
            self.allowed = allowed
        }
    }

    /// One ask on a `machines/list` row: the host's git wants `from`'s git access for `server`.
    struct GitAsk: Codable, Sendable, Hashable {
        public var server: String
        public var from: MachineRef
        public init(server: String, from: MachineRef) {
            self.server = server
            self.from = from
        }
    }

    /// What git asks a credential helper: only https, and only the server.
    struct GitCredentialRequest: Codable, Sendable, Hashable {
        public var `protocol`: String
        public var host: String
        public init(protocol: String, host: String) {
            self.protocol = `protocol`
            self.host = host
        }

        /// From what git writes on a helper's stdin (`key=value` lines). Nil unless it is
        /// https with a server: nothing is lent over plain http.
        public init?(gitAttributes text: String) {
            var fields: [String: String] = [:]
            for line in text.split(whereSeparator: \.isNewline) {
                guard let equals = line.firstIndex(of: "=") else { continue }
                fields[String(line[..<equals])] = String(line[line.index(after: equals)...])
            }
            guard fields["protocol"] == "https", let host = fields["host"], Self.isServer(host) else { return nil }
            self.init(protocol: "https", host: host)
        }

        /// A server name with an optional port, and nothing git could read as more.
        public static func isServer(_ host: String) -> Bool {
            !host.isEmpty && host.count < 256 && host.allSatisfy { $0.isLetter || $0.isNumber || "-.:[]_".contains($0) }
        }

        /// What `git credential fill` reads.
        public var gitAttributes: String { "protocol=\(self.protocol)\nhost=\(host)\n\n" }
    }

    /// A credential for one git command. Never printed, logged or kept.
    struct GitCredential: Codable, Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible,
                          CustomReflectable {
        public var username: String
        public var password: String
        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }

        /// From what `git credential fill` prints; nil without both a username and a password.
        public init?(gitAttributes text: String) {
            var username: String?
            var password: String?
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("username=") { username = String(line.dropFirst("username=".count)) }
                if line.hasPrefix("password=") { password = String(line.dropFirst("password=".count)) }
            }
            guard let username, let password, !username.isEmpty, !password.isEmpty,
                  !(username + password).contains(where: \.isNewline) else { return nil }
            self.init(username: username, password: password)
        }

        /// What a credential helper prints for git.
        public var gitAttributes: String { "username=\(username)\npassword=\(password)\n" }

        public var description: String { "git credential for \(username)" }
        public var debugDescription: String { description }
        public var customMirror: Mirror { Mirror(self, children: ["username": username]) }
    }
}

/// What every client says about lent git access (#1122), so the Mac, the Remote and the web
/// ask in the same words.
public enum GitLendWords {
    /// `lender` is nil for the Mac the person is at.
    public static func title(host: String, lender: String?, server: String) -> String {
        "Let \(host) use \(lender.map { "\($0)’s" } ?? "this Mac’s") git access for \(server)?"
    }

    public static func message(host: String, lender: String?, server: String) -> String {
        let mac = lender ?? "this Mac"
        return "Its git can then clone, pull and push on \(server) as you, through \(mac), whenever \(mac) is connected. "
            + "Nothing is kept on \(host). You can stop it in Settings ▸ Machines."
    }

    /// "Uses this Mac’s git access for github.com", for a host's row; nil when it uses none.
    public static func uses(_ row: DaemonAPI.ControlMachine, name: (MachineRef) -> String?) -> String? {
        guard let lent = row.gitFrom, !lent.isEmpty else { return nil }
        let byLender = Dictionary(grouping: lent.keys.sorted()) { lent[$0]! }
        return byLender.keys.sorted { $0.rawValue < $1.rawValue }.map { lender in
            let servers = byLender[lender]!.joined(separator: ", ")
            return "Uses \(name(lender).map { "\($0)’s" } ?? "this Mac’s") git access for \(servers)"
        }.joined(separator: " · ")
    }

    public static func revoke(_ server: String) -> String { "Stop Lending Git Access for \(server)" }
}

/// A host's git asking to use a Mac's git access (#1122), as a client shows it.
public struct GitLendAsk: Identifiable, Equatable, Sendable {
    public let host: MachineRef
    public let hostName: String
    public let server: String
    public let from: MachineRef
    /// Nil when the lender is the Mac this client is on.
    public let lenderName: String?
    public var id: String { Self.id(host, server) }

    public var title: String { GitLendWords.title(host: hostName, lender: lenderName, server: server) }
    public var message: String { GitLendWords.message(host: hostName, lender: lenderName, server: server) }

    public static func id(_ host: MachineRef, _ server: String) -> String { "\(host.rawValue) \(server)" }

    /// The first ask on `rows` not answered here yet.
    public static func first(in rows: [DaemonAPI.ControlMachine], thisMac: MachineRef?, answered: Set<String>) -> GitLendAsk? {
        for row in rows {
            for ask in row.gitAsks ?? [] where !answered.contains(id(row.id, ask.server)) {
                let lender = ask.from == thisMac ? nil : (rows.first { $0.id == ask.from }?.name ?? ask.from.rawValue)
                return GitLendAsk(host: row.id, hostName: row.name, server: ask.server, from: ask.from, lenderName: lender)
            }
        }
        return nil
    }

    /// Every ask still waiting on `rows`: an answered one no longer here may be asked again.
    public static func waiting(in rows: [DaemonAPI.ControlMachine]) -> Set<String> {
        Set(rows.flatMap { row in (row.gitAsks ?? []).map { id(row.id, $0.server) } })
    }

    /// Every lend on `rows`, for a list with Revoke.
    public static func lends(in rows: [DaemonAPI.ControlMachine]) -> [GitLend] {
        rows.flatMap { row in
            (row.gitFrom ?? [:]).keys.sorted().map { server in
                let from = row.gitFrom![server]!
                return GitLend(host: row.id, hostName: row.name, server: server, from: from,
                               lenderName: rows.first { $0.id == from }?.name ?? from.rawValue)
            }
        }
    }
}

/// A host using a Mac's git access for one git server (#1122).
public struct GitLend: Identifiable, Equatable, Sendable {
    public let host: MachineRef
    public let hostName: String
    public let server: String
    public let from: MachineRef
    public let lenderName: String
    public var id: String { GitLendAsk.id(host, server) }
}
