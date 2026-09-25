import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Lending a server's daemon a credential, one connection at a time (043, contracts/daemon.md).
///
/// Against the real daemon core with the fake launcher, which records what each runtime it
/// starts was lent. The window's side is `ServerCredentials` and `HostSet`; here the core is
/// driven through `handle`, as the socket drives it.
@Suite("Lending a credential to a server")
struct LendTests {
    static let token = "sk-ant-oat01-LENDTESTLENDTEST-a3f9"
    static let otherToken = "sk-ant-oat01-SECONDMACSECOND-b4c0"

    struct Setup {
        let core: DaemonCore
        let launcher: FakeLauncher
        let locations: StoreLocations
        let folder: URL
    }

    private func setUp(server: Bool = true, ownSignIn: Bool = false,
                       script: FakeACPAgent.Script = .init()) async throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lend-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        await core.setExitsWhenIdle(!server)
        await core.setHasOwnSignIn { _ in ownSignIn }
        return Setup(core: core, launcher: launcher, locations: locations, folder: folder)
    }

    private func call<T: Encodable>(_ setup: Setup, _ method: String, _ params: T, on connection: UUID)
        async -> Result<JSONValue, JSONRPCError> {
        await setup.core.handle(method: method, params: try? JSONValue.encoding(params), connection: connection)
    }

    private func offer(_ setup: Setup, on connection: UUID, ownSignInOnly: Bool = false) async {
        _ = await call(setup, DaemonAPI.Method.credentialsOffer,
                       DaemonAPI.CredentialsOffer(runtimes: ["claude"], ownSignInOnly: ownSignInOnly), on: connection)
    }

    private func lend(_ setup: Setup, _ text: String, on connection: UUID) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.credentialsLend,
                   DaemonAPI.CredentialsLend(runtime: "claude", secret: Secret(text)!), on: connection)
    }

    private func start(_ setup: Setup, on connection: UUID, requestID: UUID = UUID()) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.agentsStart,
                   DaemonAPI.StartRequest(runtimeID: "claude", cwd: setup.folder, prompt: "hello", requestID: requestID),
                   on: connection)
    }

    private func wanted(_ result: Result<JSONValue, JSONRPCError>) -> DaemonAPI.CredentialWanted? {
        guard case .failure(let error) = result, error.code == DaemonAPI.Failure.credentialWanted,
              let data = error.data else { return nil }
        return try? data.decode(DaemonAPI.CredentialWanted.self)
    }

    @Test func theMacsOwnDaemonTakesNoLend() async throws {
        let setup = try await setUp(server: false)
        let window = UUID()
        await offer(setup, on: window)
        guard case .failure(let error) = await lend(setup, Self.token, on: window) else {
            Issue.record("a Mac daemon took a lend"); return
        }
        #expect(error.code == DaemonAPI.Failure.notAServer)
        _ = await start(setup, on: window)
        #expect(setup.launcher.lent.allSatisfy { $0.isEmpty })
    }

    @Test func aStartWithNothingLentStartsNothingAndAsks() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window)
        let answer = await start(setup, on: window)
        #expect(wanted(answer) == DaemonAPI.CredentialWanted(runtime: "claude", offered: true))
        #expect(setup.launcher.launchCount == 0)
        #expect(await setup.core.agents.isEmpty)
    }

    @Test func afterALendTheSameStartStartsExactlyOneWithTheToken() async throws {
        let setup = try await setUp()
        let window = UUID(), requestID = UUID()
        await offer(setup, on: window)
        _ = await start(setup, on: window, requestID: requestID)
        guard case .success = await lend(setup, Self.token, on: window) else { Issue.record("lend refused"); return }
        guard case .success = await start(setup, on: window, requestID: requestID) else { Issue.record("start"); return }
        _ = await start(setup, on: window, requestID: requestID)
        #expect(setup.launcher.launchCount == 1)
        #expect(setup.launcher.lent == [["CLAUDE_CODE_OAUTH_TOKEN": Self.token]])
    }

    @Test func oneWindowsLendIsNeverAnothersStart() async throws {
        let setup = try await setUp()
        let first = UUID(), second = UUID()
        await offer(setup, on: first)
        await offer(setup, on: second)
        _ = await lend(setup, Self.token, on: first)
        #expect(wanted(await start(setup, on: second))?.offered == true)
        _ = await lend(setup, Self.otherToken, on: second)
        _ = await start(setup, on: second)
        #expect(setup.launcher.lent == [["CLAUDE_CODE_OAUTH_TOKEN": Self.otherToken]])
    }

    @Test func aClosedConnectionTakesItsLendWithIt() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window)
        _ = await lend(setup, Self.token, on: window)
        await setup.core.connectionEnded(window)
        #expect(await setup.core.lentCredentials.isEmpty)
        #expect(await setup.core.credentialOffers.isEmpty)
    }

    @Test func ownSignInOnlyStartsWithNoTokenAndRefusesALend() async throws {
        let setup = try await setUp(ownSignIn: true)
        let window = UUID()
        await offer(setup, on: window, ownSignInOnly: true)
        guard case .failure(let error) = await lend(setup, Self.token, on: window) else {
            Issue.record("took a lend"); return
        }
        #expect(error.code == DaemonAPI.Failure.notOffered)
        guard case .success = await start(setup, on: window) else { Issue.record("start"); return }
        #expect(setup.launcher.lent == [[:]])
    }

    @Test func aWindowWithNothingToLendIsAskedToAskOnlyWhenTheServerHasNoSignIn() async throws {
        let bare = try await setUp(ownSignIn: false)
        let window = UUID()
        _ = await bare.core.handle(method: DaemonAPI.Method.credentialsOffer,
                                   params: try JSONValue.encoding(DaemonAPI.CredentialsOffer(runtimes: [], ownSignInOnly: false)),
                                   connection: window)
        #expect(wanted(await start(bare, on: window)) == DaemonAPI.CredentialWanted(runtime: "claude", offered: false))

        let signedIn = try await setUp(ownSignIn: true)
        guard case .success = await start(signedIn, on: window) else { Issue.record("start"); return }
        #expect(signedIn.launcher.lent == [[:]])
    }

    @Test func theLentTokenReplacesAnyClaudeVariableTheServerHad() {
        let before = ["PATH": "/usr/bin", "ANTHROPIC_API_KEY": "sk-ant-api03-servers-own", "CLAUDE_CODE_OAUTH_TOKEN": "old"]
        let after = LentEnvironment.$value.withValue(["CLAUDE_CODE_OAUTH_TOKEN": Self.token]) {
            LentEnvironment.applied(to: before)
        }
        #expect(after == ["PATH": "/usr/bin", "CLAUDE_CODE_OAUTH_TOKEN": Self.token])
        #expect(LentEnvironment.applied(to: before) == before)
    }

    @Test func theTokenIsWrittenNowhereUnderTheRoot() async throws {
        let setup = try await setUp()
        let window = UUID(), requestID = UUID()
        await offer(setup, on: window)
        _ = await start(setup, on: window, requestID: requestID)
        _ = await lend(setup, Self.token, on: window)
        _ = await start(setup, on: window, requestID: requestID)
        try await Task.sleep(for: .milliseconds(300))
        let e = FileManager.default.enumerator(at: setup.locations.root, includingPropertiesForKeys: nil)
        while let file = e?.nextObject() as? URL {
            guard let data = try? Data(contentsOf: file) else { continue }
            #expect(!String(decoding: data, as: UTF8.self).contains("LENDTEST"), "\(file.lastPathComponent)")
        }
    }

    /// What claude-agent-acp 0.81.2 answered a made-up token with (walk/spike.md T009).
    static let refusal = JSONRPCError(
        code: -32603, message: "Internal error: Failed to authenticate. API Error: 401 OAuth access token is invalid.",
        data: ["errorKind": "authentication_failed"])

    @Test func aRefusedTokenStopsTheAgentSayingSoAndNotStoppedAnswering() async throws {
        let setup = try await setUp(script: .init(promptError: Self.refusal))
        let window = UUID(), requestID = UUID()
        await offer(setup, on: window)
        _ = await lend(setup, Self.token, on: window)
        guard case .success(let made) = await start(setup, on: window, requestID: requestID),
              let id = made.stringValue.flatMap(UUID.init(uuidString:)) else { Issue.record("start"); return }
        var notes: [String] = []
        for _ in 0..<50 {
            notes = try await setup.core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
                if case .runtimeNote(let text) = $0.kind { return text } else { return nil }
            }
            if notes.contains(where: { $0.contains("refused") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(notes.contains("Claude refused the token in Settings. Replace it in Settings ▸ Servers."))
        #expect(!notes.contains { $0.contains("stopped answering") })
    }

    @Test func onlyAnAuthenticationFailureCounts() {
        #expect(DaemonCore.isAuthenticationFailure(Self.refusal))
        #expect(!DaemonCore.isAuthenticationFailure(JSONRPCError(code: -32000, message: "Authentication required")))
        #expect(!DaemonCore.isAuthenticationFailure(JSONRPCError(code: -32603, message: "Internal error: overloaded")))
    }
}
