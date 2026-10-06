#if canImport(CryptoKit) && canImport(Network)
import CryptoKit
import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Signing in to an MCP server that asks for OAuth (#306), against a fake authorization
/// server and MCP server: no real network. The browser is the test, following the
/// authorization URL's redirect to the daemon's loopback callback.
@Suite("MCP sign-in", .timeLimit(.minutes(1)))
struct MCPSignInTests {
    private static let sentinel = "SENTINEL-306-oauth"

    private struct World {
        let locations: StoreLocations
        let home: URL
        let core: DaemonCore
        let fake: FakeOAuth
        var signIns: URL { MCPSignInFile.url(home: home) }
        var mcp: URL { MCPJSONFile.personalURL(home: home) }
    }

    private func world(registration: Bool = true, lines: SignInLines? = nil) async throws -> World {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "MCPSignInTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        let home = base.appending(path: "home")
        for url in [base.appending(path: "root"), home.appending(path: ".agents")] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var locations = StoreLocations(root: base.appending(path: "root"))
        locations.personalHome = home
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: FakeLauncher())
        let fake = FakeOAuth(registration: registration)
        await core.setMCPSignIn(http: fake.send, waitLimit: .seconds(5), log: lines?.add)
        await core.setMCPVerify(timeout: .seconds(5), http: fake.send)
        try #"{"mcpServers": {"gh": {"type": "http", "url": "https://MCP.example/mcp"}}}"#
            .write(to: MCPJSONFile.personalURL(home: home), atomically: true, encoding: .utf8)
        return World(locations: locations, home: home, core: core, fake: fake)
    }

    /// Be the browser: the authorization server answers at once with a code, so go
    /// straight to the redirect with it and the state.
    private func approveInBrowser(_ address: String, code: String = "code-1", fake: FakeOAuth? = nil) async throws -> (page: String, query: [String: String]) {
        let parts = try #require(URLComponents(string: address))
        var query: [String: String] = [:]
        for item in parts.queryItems ?? [] { query[item.name] = item.value }
        fake?.expect(challenge: query["code_challenge"])
        let redirect = try #require(query["redirect_uri"])
        var back = try #require(URLComponents(string: redirect))
        back.queryItems = [.init(name: "code", value: code), .init(name: "state", value: query["state"]),
                           .init(name: "iss", value: "https://auth.example")]
        let (data, _) = try await URLSession(configuration: .ephemeral).data(from: try #require(back.url))
        return (String(decoding: data, as: UTF8.self), query)
    }

    private func signIn(_ w: World) async throws -> [String: String] {
        let started = await w.core.mcpSignIn(.init(target: .entry(destination: .personal, name: "gh")))
        #expect(started.error == nil)
        let flow = try #require(started.flowID)
        let (page, query) = try await approveInBrowser(try #require(started.authorizationURL), fake: w.fake)
        #expect(page.contains("Signed in to gh"))
        #expect(await w.core.mcpSignInWait(.init(flowID: flow)).status == .signedIn)
        return query
    }

    // MARK: Discovery

    @Test func discoveryFollowsTheChallengeToTheAuthorizationServer() async throws {
        let fake = FakeOAuth(registration: true)
        let plan = try await MCPOAuth.discover(server: "https://mcp.example/mcp",
                                               resourceMetadata: "https://mcp.example/.well-known/oauth-protected-resource/mcp",
                                               http: fake.send)
        #expect(plan.resource == "https://mcp.example/mcp")
        #expect(plan.server.issuer == "https://auth.example")
        #expect(plan.server.registrationEndpoint == "https://auth.example/register")
        #expect(plan.scopes == ["mcp:read", "offline_access"])
    }

    @Test func wellKnownPlacesAreAskedInTheSpecsOrder() {
        #expect(MCPOAuth.resourceMetadataURLs(server: "https://a.example/mcp/", named: nil).map(\.absoluteString) ==
                ["https://a.example/.well-known/oauth-protected-resource/mcp/",
                 "https://a.example/.well-known/oauth-protected-resource"])
        #expect(MCPOAuth.authorizationServerMetadataURLs(issuer: "https://github.com/login/oauth").map(\.absoluteString) ==
                ["https://github.com/.well-known/oauth-authorization-server/login/oauth",
                 "https://github.com/.well-known/openid-configuration/login/oauth",
                 "https://github.com/login/oauth/.well-known/openid-configuration"])
        #expect(MCPOAuth.authorizationServerMetadataURLs(issuer: "https://auth.example").map(\.absoluteString) ==
                ["https://auth.example/.well-known/oauth-authorization-server",
                 "https://auth.example/.well-known/openid-configuration"])
        #expect(MCPOAuth.canonical("HTTPS://MCP.Example:443/mcp#x") == "https://mcp.example/mcp")
        #expect(MCPOAuth.challengeScope(#"Bearer error="insufficient_scope", scope="a b""#) == ["a", "b"])
    }

    @Test func metadataForAnotherServerIsRefused() async {
        let fake = FakeOAuth(registration: true, resource: "https://elsewhere.example/mcp")
        await #expect(throws: MCPOAuth.Failure.resourceMismatch) {
            try await MCPOAuth.discover(server: "https://mcp.example/mcp", resourceMetadata: nil, http: fake.send)
        }
    }

    @Test func anAuthorizationServerWithoutS256IsRefused() async {
        let fake = FakeOAuth(registration: true, pkce: ["plain"])
        await #expect(throws: MCPOAuth.Failure.noPKCE) {
            try await MCPOAuth.discover(server: "https://mcp.example/mcp", resourceMetadata: nil, http: fake.send)
        }
    }

    // MARK: PKCE

    @Test func pkceIsS256OfTheVerifier() {
        // base64url(SHA-256(verifier)), unpadded: worked out apart from the app, with
        // Python's hashlib and base64.urlsafe_b64encode.
        #expect(MCPOAuth.challenge("dBjftJeZ4CVP-mJ92K9qkPAyHmJp9aJh1ZDwyF2xnr0") == "ekO6Un3n1AQxLb-AASkYCetMD6I2hBuIiaZS0yJBGg8")
        let verifier = MCPOAuth.randomToken()
        #expect(verifier.count == 43)
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(verifier != MCPOAuth.randomToken())
    }

    // MARK: The whole sign-in

    @Test func aServerThatAsksIsNamedThenSignedInAndKeptOutOfMcpJson() async throws {
        let w = try await world()
        let mcpBefore = try Data(contentsOf: w.mcp)

        let before = try await w.core.mcpList(.init(destination: .personal))
        #expect(before.servers.first?.signIn == .needsSignIn)

        let query = try await signIn(w)
        #expect(query["client_id"] == "client-1", "registered itself")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["resource"] == "https://mcp.example/mcp")
        #expect(query["scope"] == "mcp:read offline_access")
        #expect(query["redirect_uri"]?.hasPrefix("http://127.0.0.1:") == true)
        #expect(w.fake.verifierMatched, "the token request carried the verifier for that challenge")
        #expect(w.fake.tokenResource == "https://mcp.example/mcp")

        let after = try await w.core.mcpList(.init(destination: .personal))
        #expect(after.servers.first?.signIn == .signedIn)
        #expect(try Data(contentsOf: w.mcp) == mcpBefore, "mcp.json is not written")
        let attributes = try FileManager.default.attributesOfItem(atPath: w.signIns.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(try String(contentsOf: w.signIns, encoding: .utf8).contains(FakeOAuth.access(1)))

        // The next agent starts with it, and its bearer.
        let servers = try await w.core.sessionServers(runtimeID: "claude", chosen: [], token: "t", managesAgents: true,
                                                      cwd: w.home, capabilities: ACP.MCPCapabilities(http: true, sse: false))
        #expect(servers.map(\.name) == ["agents", "gh"])
        #expect(servers.last?.transport == .http(url: "https://MCP.example/mcp",
                                                 headers: ["Authorization": "Bearer \(FakeOAuth.access(1))"]))

        // Sign out: forgotten, and the row asks again.
        #expect(await w.core.mcpSignOut(.init(target: .entry(destination: .personal, name: "gh"))).error == nil)
        #expect(!(try String(contentsOf: w.signIns, encoding: .utf8)).contains(FakeOAuth.access(1)))
        #expect(try await w.core.mcpList(.init(destination: .personal)).servers.first?.signIn == .needsSignIn)
    }

    @Test func aServerThatStillNeedsSignInIsLeftOutAtSessionStart() async throws {
        let w = try await world()
        _ = try await w.core.mcpList(.init(destination: .personal))
        let servers = try await w.core.sessionServers(runtimeID: "claude", chosen: [], token: "t", managesAgents: true,
                                                      cwd: w.home, capabilities: ACP.MCPCapabilities(http: true, sse: false))
        #expect(servers.map(\.name) == ["agents"])
        let snapshot = PersonalDotAgents.snapshot(home: w.home, installed: ["claude"], record: .init(home: w.home.path))
        #expect(snapshot.needsALook.contains { $0.item == "gh" && $0.text.contains("needs sign-in") })
    }

    @Test func aTokenAboutToEndIsRefreshedBeforeAnAgentStarts() async throws {
        let w = try await world()
        _ = try await signIn(w)
        // An hour on: the token has ended.
        let later = Date().addingTimeInterval(3600)
        await w.core.setMCPSignIn(http: w.fake.send, now: { later })
        let servers = try await w.core.sessionServers(runtimeID: "claude", chosen: [], token: "t", managesAgents: true,
                                                      cwd: w.home, capabilities: ACP.MCPCapabilities(http: true, sse: false))
        #expect(servers.last?.transport == .http(url: "https://MCP.example/mcp",
                                                 headers: ["Authorization": "Bearer \(FakeOAuth.access(2))"]))
        #expect(w.fake.refreshes == 1)
        let kept = try String(contentsOf: w.signIns, encoding: .utf8)
        #expect(kept.contains(FakeOAuth.access(2)) && kept.contains("r306tok-2"), "the rotated refresh token is kept")

        // Refreshes at once from two starts are one refresh.
        let later2 = later.addingTimeInterval(3600)
        await w.core.setMCPSignIn(http: w.fake.send, now: { later2 })
        let signIns = await w.core.mcpSignIns
        async let a = signIns.bearer(server: "https://mcp.example/mcp", name: "gh")
        async let b = signIns.bearer(server: "https://mcp.example/mcp", name: "gh")
        #expect(await [a, b] == [.token(FakeOAuth.access(3)), .token(FakeOAuth.access(3))])
        #expect(w.fake.refreshes == 2)

        // A refresh token no longer taken: needs sign-in again, and left out.
        w.fake.refuseRefresh = true
        let later3 = later2.addingTimeInterval(3600)
        await w.core.setMCPSignIn(http: w.fake.send, now: { later3 })
        let left = try await w.core.sessionServers(runtimeID: "claude", chosen: [], token: "t", managesAgents: true,
                                                   cwd: w.home, capabilities: ACP.MCPCapabilities(http: true, sse: false))
        #expect(left.map(\.name) == ["agents"])
        #expect(try await w.core.mcpList(.init(destination: .personal)).servers.first?.signIn == .needsSignIn)
    }

    @Test func withoutRegistrationThePersonsOwnClientIsAskedForAndKept() async throws {
        let w = try await world(registration: false)
        let first = await w.core.mcpSignIn(.init(target: .entry(destination: .personal, name: "gh")))
        #expect(first.needsClient == "https://auth.example")
        #expect(first.flowID == nil)

        let started = await w.core.mcpSignIn(.init(target: .entry(destination: .personal, name: "gh"),
                                                   client: .init(id: "mine", secret: "shh-\(Self.sentinel)")))
        let (_, query) = try await approveInBrowser(try #require(started.authorizationURL))
        #expect(query["client_id"] == "mine")
        #expect(await w.core.mcpSignInWait(.init(flowID: try #require(started.flowID))).status == .signedIn)
        #expect(w.fake.tokenClientSecret == "shh-\(Self.sentinel)")
        // Kept for next time: no question the second time.
        let again = await w.core.mcpSignIn(.init(target: .entry(destination: .personal, name: "gh")))
        #expect(again.needsClient == nil && again.authorizationURL != nil)
        _ = await w.core.mcpSignInCancel(.init(flowID: try #require(again.flowID)))
    }

    @Test func aWrongStateIsNotTheCallbackAndCancelEndsIt() async throws {
        let w = try await world()
        let started = await w.core.mcpSignIn(.init(target: .entry(destination: .personal, name: "gh")))
        let address = try #require(started.authorizationURL)
        var parts = try #require(URLComponents(string: address))
        let redirect = try #require(parts.queryItems?.first { $0.name == "redirect_uri" }?.value)
        parts = try #require(URLComponents(string: redirect))
        parts.queryItems = [.init(name: "code", value: "code-1"), .init(name: "state", value: "forged")]
        let (_, response) = try await URLSession(configuration: .ephemeral).data(from: try #require(parts.url))
        #expect((response as? HTTPURLResponse)?.statusCode == 400)
        #expect(w.fake.exchanges == 0)

        let flow = try #require(started.flowID)
        _ = await w.core.mcpSignInCancel(.init(flowID: flow))
        #expect(await w.core.mcpSignInWait(.init(flowID: flow)).status != .signedIn)
        let kept = (try? String(contentsOf: w.signIns, encoding: .utf8)) ?? ""
        #expect(!kept.contains(FakeOAuth.access(1)))
    }

    @Test func verifyWaitsOnTheSignInThenAnswersWithIt() async throws {
        let w = try await world()
        let hand = DaemonAPI.MCPHandServer(name: "team", kind: .url, url: "https://mcp.example/mcp")
        let first = await w.core.mcpVerify(.init(destination: .personal, server: hand))
        guard case .authRequired = first.outcome else { Issue.record("not auth required"); return }

        let started = await w.core.mcpSignIn(.init(target: .url(name: "team", url: hand.url)))
        _ = try await approveInBrowser(try #require(started.authorizationURL))
        #expect(await w.core.mcpSignInWait(.init(flowID: try #require(started.flowID))).status == .signedIn)

        let second = await w.core.mcpVerify(.init(destination: .personal, server: hand))
        #expect(second.outcome == .answered(serverName: "stand-in", version: "2", tools: ["a", "b"]))
        let entry = String(decoding: try JSONEncoder().encode(second.entry ?? [:]), as: UTF8.self)
        #expect(!entry.contains("a306tok"), "the bearer is not written into the entry")
    }

    // MARK: Never logged

    @Test func noTokenCodeOrSecretReachesTheLog() async throws {
        let lines = SignInLines()
        let w = try await world(registration: false, lines: lines)
        let log = w.locations.root.appending(path: "sign-in.log")
        DaemonLog.shared.setDestination(log)
        defer { DaemonLog.shared.setDestination(nil) }
        _ = try await w.core.mcpList(.init(destination: .personal))
        let started = await w.core.mcpSignIn(.init(target: .entry(destination: .personal, name: "gh"),
                                                   client: .init(id: "mine", secret: Self.sentinel)))
        _ = try await approveInBrowser(try #require(started.authorizationURL), code: "code-\(Self.sentinel)")
        _ = await w.core.mcpSignInWait(.init(flowID: try #require(started.flowID)))
        let later = Date().addingTimeInterval(3600)
        await w.core.setMCPSignIn(http: w.fake.send, now: { later }, log: lines.add)
        _ = try await w.core.sessionServers(runtimeID: "claude", chosen: [], token: "t", managesAgents: true,
                                            cwd: w.home, capabilities: ACP.MCPCapabilities(http: true, sse: false))
        _ = await w.core.mcpSignOut(.init(target: .entry(destination: .personal, name: "gh")))
        DaemonLog.shared.setDestination(nil)
        // The daemon's log is one for the whole process, and other suites write to it too:
        // only what can only be this test's is looked for there. The sign-ins' own log is
        // this test's alone, so nothing of an address is allowed in it either.
        let daemon = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let mine = lines.all
        #expect(mine.contains("gh signed in"), "it did log")
        for secret in [Self.sentinel, "a306tok", "r306tok"] {
            #expect(!daemon.contains(secret), "\(secret) reached the daemon log")
            #expect(!mine.contains(secret), "\(secret) reached the sign-ins' log")
        }
        for address in ["mcp.example", "auth.example", "127.0.0.1"] {
            #expect(!mine.contains(address), "\(address) reached the sign-ins' log")
        }
    }
}

/// An MCP server that asks for OAuth, and its authorization server, answering as the specs
/// say. Tokens are `access-N` and `refresh-N`, N counting each one issued.
final class FakeOAuth: @unchecked Sendable {
    private let lock = NSLock()
    private let registration: Bool
    private let resource: String
    private let pkce: [String]
    private var challenge: String?
    private var issued = 0
    private var _refreshes = 0
    private var _exchanges = 0
    private var _verifierMatched = false
    private var _tokenResource: String?
    private var _tokenClientSecret: String?
    private var _refuseRefresh = false
    private let mcp = StandIn()

    static func access(_ n: Int) -> String { "a306tok-\(n)" }

    init(registration: Bool, resource: String = "https://mcp.example/mcp", pkce: [String] = ["S256"]) {
        self.registration = registration
        self.resource = resource
        self.pkce = pkce
    }

    var refreshes: Int { lock.withLock { _refreshes } }
    var exchanges: Int { lock.withLock { _exchanges } }
    var verifierMatched: Bool { lock.withLock { _verifierMatched } }
    var tokenResource: String? { lock.withLock { _tokenResource } }
    var tokenClientSecret: String? { lock.withLock { _tokenClientSecret } }
    var refuseRefresh: Bool {
        get { lock.withLock { _refuseRefresh } }
        set { lock.withLock { _refuseRefresh = newValue } }
    }

    var send: MCPClient.HTTPSend {
        { [self] request in try await self.answer(request) }
    }

    private func answer(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        func reply(_ status: Int, _ text: String, _ headers: [String: String] = ["Content-Type": "application/json"])
            -> (Data, HTTPURLResponse) {
            (Data(text.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        switch (url.host?.lowercased(), url.path) {
        case ("mcp.example", "/mcp"):
            let bearer = request.value(forHTTPHeaderField: "Authorization") ?? ""
            let good = lock.withLock { issued > 0 && bearer == "Bearer a306tok-\(issued)" }
            guard good else {
                return reply(401, "", ["WWW-Authenticate":
                    #"Bearer resource_metadata="https://mcp.example/.well-known/oauth-protected-resource/mcp""#])
            }
            return try await mcp.send(request)
        case ("mcp.example", "/.well-known/oauth-protected-resource/mcp"):
            return reply(200, #"{"resource":"\#(resource)","authorization_servers":["https://auth.example"],"scopes_supported":["mcp:read"]}"#)
        case ("auth.example", "/.well-known/oauth-authorization-server"):
            let methods = pkce.map { "\"\($0)\"" }.joined(separator: ",")
            let register = registration ? #","registration_endpoint":"https://auth.example/register""# : ""
            return reply(200, #"{"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize","token_endpoint":"https://auth.example/token","code_challenge_methods_supported":[\#(methods)],"scopes_supported":["mcp:read","offline_access"]\#(register)}"#)
        case ("auth.example", "/register") where registration:
            let body = request.httpBody.flatMap { try? JSONValue.parse($0) }
            guard body?["token_endpoint_auth_method"]?.stringValue == "none",
                  body?["redirect_uris"]?.arrayValue?.first?.stringValue?.hasPrefix("http://127.0.0.1:") == true
            else { return reply(400, #"{"error":"invalid_redirect_uri"}"#) }
            return reply(201, #"{"client_id":"client-1"}"#)
        case ("auth.example", "/token"):
            return token(request, reply: reply)
        default:
            return reply(404, "")
        }
    }

    /// The challenge the authorization URL carried, as the browser saw it.
    func expect(challenge: String?) { lock.withLock { self.challenge = challenge } }

    private func token(_ request: URLRequest,
                       reply: (Int, String, [String: String]) -> (Data, HTTPURLResponse)) -> (Data, HTTPURLResponse) {
        let json = ["Content-Type": "application/json"]
        let form = MCPOAuth.formJSON(request.httpBody ?? Data())
        switch form["grant_type"]?.stringValue {
        case "authorization_code":
            guard let verifier = form["code_verifier"]?.stringValue, form["code"]?.stringValue?.hasPrefix("code-") == true else {
                return reply(400, #"{"error":"invalid_request"}"#, json)
            }
            let n = lock.withLock { () -> Int in
                _exchanges += 1
                let made = MCPOAuth.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
                _verifierMatched = challenge != nil && made == challenge
                _tokenResource = form["resource"]?.stringValue
                _tokenClientSecret = form["client_secret"]?.stringValue
                issued += 1
                return issued
            }
            return reply(200, #"{"access_token":"a306tok-\#(n)","refresh_token":"r306tok-\#(n)","expires_in":3600,"token_type":"Bearer"}"#, json)
        case "refresh_token":
            let n = lock.withLock { () -> Int? in
                guard !_refuseRefresh, form["refresh_token"]?.stringValue == "r306tok-\(issued)" else { return nil }
                _refreshes += 1
                issued += 1
                return issued
            }
            guard let n else { return reply(400, #"{"error":"invalid_grant"}"#, json) }
            return reply(200, #"{"access_token":"a306tok-\#(n)","refresh_token":"r306tok-\#(n)","expires_in":3600}"#, json)
        default:
            return reply(400, #"{"error":"unsupported_grant_type"}"#, json)
        }
    }
}

final class SignInLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var all: String { lock.withLock { lines.joined(separator: "\n") } }
    var add: @Sendable (String) -> Void { { [self] line in lock.withLock { lines.append(line) } } }
}
#endif
