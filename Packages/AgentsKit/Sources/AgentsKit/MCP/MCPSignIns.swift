import AgentsKitCore
import Foundation

/// `~/.agents/mcp-sign-ins.json` (#306): the person's MCP sign-ins, beside `secrets.env` and
/// kept as it is: mode 0600, written whole, in the person's own home (a scratch root's in
/// its scratch home). Keyed by the server's address as a resource, so a server named in
/// both `~/.agents/mcp.json` and a project's is signed in to once.
///
/// Never in `mcp.json`, never in a log, never in anything the daemon answers a client
/// with: a client is only ever told *signed in* or *needs sign-in*.
struct MCPSignInFile: Codable, Equatable, Sendable {
    /// What a sign-in left: what to send, and how to renew it.
    struct Grant: Codable, Equatable, Sendable {
        var issuer: String
        var tokenEndpoint: String
        var revocationEndpoint: String?
        var client: MCPOAuth.Client
        var access: String
        var refresh: String?
        var expiresAt: Date?
        var signedInAt: Date
    }

    /// A server that answered 401 and has no grant.
    struct NeedsSignIn: Codable, Equatable, Sendable {
        var resourceMetadata: String?
        var seenAt: Date
    }

    var grants: [String: Grant] = [:]
    var needsSignIn: [String: NeedsSignIn] = [:]
    /// Clients the person registered themselves, by issuer: for an authorization server
    /// with no dynamic registration (GitHub's).
    var clients: [String: MCPOAuth.Client] = [:]

    static let fileName = "mcp-sign-ins.json"

    static func url(home: URL) -> URL {
        home.appending(path: PersonalDotAgents.folder).appending(path: fileName)
    }

    struct Unreadable: Error {}

    /// A missing file is empty. One that is there and does not read is refused, so a write
    /// never replaces sign-ins it could not read.
    static func load(from url: URL) throws -> MCPSignInFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return MCPSignInFile() }
        guard let data = try? Data(contentsOf: url),
              let file = try? decoder.decode(MCPSignInFile.self, from: data) else { throw Unreadable() }
        return file
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try StoreCoding.writeAtomically(try encoder.encode(self), to: url, permissions: 0o600)
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// The daemon's keeper of MCP sign-ins (#306): what a server's row says, the bearer an agent
/// starts with (refreshed first when it is about to end), and sign-out. One refresh at a
/// time per server: a refresh token that rotates is spent by the first.
actor MCPSignIns {
    /// What an agent's session is given for a server.
    enum Bearer: Equatable, Sendable {
        /// Not a server the app has signed in to, nor one known to want it: it goes as it is.
        case none
        case token(String)
        /// It wants a sign-in and has none that works: agents start without it.
        case needsSignIn
    }

    /// Renew a token this close to its end.
    static let refreshMargin: TimeInterval = 120

    private let home: URL?
    private let http: MCPClient.HTTPSend
    private let log: @Sendable (String) -> Void
    private let now: @Sendable () -> Date
    private var refreshing: [String: Task<Bearer, Never>] = [:]
    /// Servers asked once this run whether they want a sign-in, and what they said.
    private var probed: [String: Bool] = [:]

    init(home: URL?, http: MCPClient.HTTPSend? = nil,
         log: @escaping @Sendable (String) -> Void = { DaemonLog.shared.write($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.http = http ?? MCPClient.urlSession
        self.log = log
        self.now = now
    }

    var httpSend: MCPClient.HTTPSend { http }

    private var url: URL? { home.map(MCPSignInFile.url(home:)) }

    private func read() -> MCPSignInFile {
        guard let url else { return MCPSignInFile() }
        return (try? MCPSignInFile.load(from: url)) ?? MCPSignInFile()
    }

    /// Change the file, or nothing when it is there and unreadable.
    private func change(_ edit: (inout MCPSignInFile) -> Void) throws {
        guard let url else { return }
        var file = try MCPSignInFile.load(from: url)
        edit(&file)
        try file.save(to: url)
    }

    // MARK: What a row says

    /// `signedIn`, `needsSignIn`, or nil for a server the app has nothing on.
    func state(server: String) -> DaemonAPI.MCPSignInState? {
        guard let key = MCPOAuth.canonical(server) else { return nil }
        let file = read()
        if file.grants[key] != nil { return .signedIn }
        if file.needsSignIn[key] != nil { return .needsSignIn }
        return nil
    }

    /// Whether a server was asked this run, so a list asks each once.
    func wasProbed(server: String) -> Bool {
        MCPOAuth.canonical(server).map { probed[$0] != nil } ?? true
    }

    func noteProbe(server: String, wantsSignIn: Bool) {
        guard let key = MCPOAuth.canonical(server) else { return }
        probed[key] = wantsSignIn
    }

    func resourceMetadata(server: String) -> String? {
        MCPOAuth.canonical(server).flatMap { read().needsSignIn[$0]?.resourceMetadata }
    }

    /// The server answered 401: unless a grant is held, name it on its row.
    func markNeedsSignIn(server: String, name: String, resourceMetadata: String?) {
        guard let key = MCPOAuth.canonical(server) else { return }
        probed[key] = true
        do {
            try change { file in
                guard file.grants[key] == nil else { return }
                file.needsSignIn[key] = .init(resourceMetadata: resourceMetadata, seenAt: now())
            }
            log("mcp sign-in: \(name) needs sign-in")
        } catch {
            log("mcp sign-in: \(name) needs sign-in; \(MCPSignInFile.fileName) could not be read, so nothing was kept")
        }
    }

    // MARK: Clients the person registered

    func client(issuer: String) -> MCPOAuth.Client? { read().clients[issuer] }

    func keepClient(_ client: MCPOAuth.Client, issuer: String) throws {
        try change { $0.clients[issuer] = client }
    }

    // MARK: A sign-in, kept

    func keep(server: String, name: String, plan: MCPOAuth.Plan, client: MCPOAuth.Client, tokens: MCPOAuth.Tokens) throws {
        guard let key = MCPOAuth.canonical(server) else { return }
        let at = now()
        try change { file in
            file.grants[key] = .init(issuer: plan.server.issuer, tokenEndpoint: plan.server.tokenEndpoint,
                                     revocationEndpoint: plan.server.revocationEndpoint, client: client,
                                     access: tokens.access, refresh: tokens.refresh,
                                     expiresAt: tokens.expiresIn.map { at.addingTimeInterval(TimeInterval($0)) },
                                     signedInAt: at)
            file.needsSignIn[key] = nil
        }
        probed[key] = true
        log("mcp sign-in: \(name) signed in")
    }

    /// Forget the grant, revoking it first where the server offers that. The server is
    /// then one that needs a sign-in.
    func signOut(server: String, name: String) async throws {
        guard let key = MCPOAuth.canonical(server) else { return }
        if let grant = read().grants[key], let endpoint = grant.revocationEndpoint {
            await MCPOAuth.revoke(grant.refresh ?? grant.access, at: endpoint, client: grant.client, http: http)
        }
        try change { file in
            file.grants[key] = nil
            file.needsSignIn[key] = .init(resourceMetadata: nil, seenAt: now())
        }
        log("mcp sign-in: \(name) signed out")
    }

    // MARK: An agent starting

    /// The bearer to send `server` with, refreshed first when it ends within
    /// `refreshMargin`. A refresh token no longer taken leaves the server needing a sign-in.
    func bearer(server: String, name: String) async -> Bearer {
        guard let key = MCPOAuth.canonical(server) else { return .none }
        if let running = refreshing[key] { return await running.value }
        let file = read()
        guard let grant = file.grants[key] else {
            return file.needsSignIn[key] != nil ? .needsSignIn : .none
        }
        let current = now()
        guard let expires = grant.expiresAt, expires.timeIntervalSince(current) < Self.refreshMargin else {
            return .token(grant.access)
        }
        guard let refresh = grant.refresh else {
            return expires > current ? .token(grant.access) : expire(key, name: name, why: "its token ended")
        }
        let task = Task { await self.renew(key, name: name, grant: grant, refreshToken: refresh) }
        refreshing[key] = task
        let bearer = await task.value
        refreshing[key] = nil
        return bearer
    }

    private func renew(_ key: String, name: String, grant: MCPSignInFile.Grant, refreshToken: String) async -> Bearer {
        do {
            let tokens = try await MCPOAuth.refresh(refreshToken, tokenEndpoint: grant.tokenEndpoint,
                                                    client: grant.client, resource: key, http: http)
            let at = now()
            try? change { file in
                guard var kept = file.grants[key] else { return }
                kept.access = tokens.access
                // A server that does not rotate it answers without one: the old one stands.
                kept.refresh = tokens.refresh ?? kept.refresh
                kept.expiresAt = tokens.expiresIn.map { at.addingTimeInterval(TimeInterval($0)) }
                file.grants[key] = kept
            }
            log("mcp sign-in: \(name) refreshed")
            return .token(tokens.access)
        } catch MCPOAuth.Failure.invalidGrant {
            return expire(key, name: name, why: "its sign-in has ended")
        } catch {
            // Not reached, or refused for now: the token there is still good if it has not
            // ended yet.
            let word = (error as? MCPOAuth.Failure)?.logWord ?? "failed"
            if let expires = grant.expiresAt, expires > now() {
                log("mcp sign-in: \(name) refresh \(word); using the token it has")
                return .token(grant.access)
            }
            log("mcp sign-in: \(name) refresh \(word)")
            return .needsSignIn
        }
    }

    private func expire(_ key: String, name: String, why: String) -> Bearer {
        try? change { file in
            file.grants[key] = nil
            file.needsSignIn[key] = .init(resourceMetadata: nil, seenAt: now())
        }
        log("mcp sign-in: \(name) needs sign-in: \(why)")
        return .needsSignIn
    }

    /// Whether the entry brings its own `Authorization`: then a 401 is about that, and the
    /// app does not sign in for it.
    static func bringsOwnAuthorization(_ headers: [String: String]) -> Bool {
        headers.keys.contains { $0.lowercased() == "authorization" }
    }

    /// `servers`, each http one the app signed in to with its bearer in its headers, and
    /// those that need a sign-in left out (named in `leftOut`). `keep` names any to pass
    /// through untouched (the app's own).
    func signedIn(_ servers: [MCPServer], except keep: Set<String>) async
        -> (servers: [MCPServer], leftOut: [String]) {
        var out: [MCPServer] = []
        var leftOut: [String] = []
        for server in servers {
            guard !keep.contains(server.name), case .http(let address, var headers) = server.transport,
                  !Self.bringsOwnAuthorization(headers) else {
                out.append(server)
                continue
            }
            switch await bearer(server: address, name: server.name) {
            case .none:
                out.append(server)
            case .token(let token):
                headers["Authorization"] = "Bearer \(token)"
                out.append(MCPServer(name: server.name, transport: .http(url: address, headers: headers)))
            case .needsSignIn:
                leftOut.append(server.name)
            }
        }
        return (out, leftOut)
    }
}
