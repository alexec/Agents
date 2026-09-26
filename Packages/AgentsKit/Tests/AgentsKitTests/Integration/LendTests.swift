import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// Lending a server's daemon a credential, one connection at a time (043, contracts/daemon.md).
/// Gemini's key is the only kind lent since 056; Claude signs in through the Mac's relay,
/// and says so when it cannot (`signInWanted`).
///
/// Against the real daemon core with the fake launcher, which records what each runtime it
/// starts was lent. The window's side is `ServerCredentials` and `HostSet`; here the core is
/// driven through `handle`, as the socket drives it.
@Suite("Lending a credential to a server")
struct LendTests {
    static let token = "AQ." + "Ab8RN6FAKE-LENDTESTLENDTEST-a3f9"
    static let otherToken = "AQ." + "Ab8RN6FAKE-SECONDMACSECOND-b4c0"

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
                       DaemonAPI.CredentialsOffer(runtimes: ["gemini"], ownSignInOnly: ownSignInOnly), on: connection)
    }

    private func lend(_ setup: Setup, _ text: String, on connection: UUID) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.credentialsLend,
                   DaemonAPI.CredentialsLend(runtime: "gemini", secret: Secret(text)!), on: connection)
    }

    private func start(_ setup: Setup, on connection: UUID, requestID: UUID = UUID(),
                       runtime: String = "gemini") async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.agentsStart,
                   DaemonAPI.StartRequest(runtimeID: runtime, cwd: setup.folder, prompt: "hello", requestID: requestID),
                   on: connection)
    }

    private func wanted(_ result: Result<JSONValue, JSONRPCError>) -> DaemonAPI.CredentialWanted? {
        guard case .failure(let error) = result, error.code == DaemonAPI.Failure.credentialWanted,
              let data = error.data else { return nil }
        return try? data.decode(DaemonAPI.CredentialWanted.self)
    }


    @Test func aStartWithNothingLentStartsNothingAndAsks() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window)
        let answer = await start(setup, on: window)
        #expect(wanted(answer) == DaemonAPI.CredentialWanted(runtime: "gemini", offered: true))
        #expect(setup.launcher.launchCount == 0)
        #expect(await setup.core.agents.isEmpty)
    }

    @Test func afterALendTheSameStartStartsExactlyOneWithTheKey() async throws {
        let setup = try await setUp()
        let window = UUID(), requestID = UUID()
        await offer(setup, on: window)
        _ = await start(setup, on: window, requestID: requestID)
        guard case .success = await lend(setup, Self.token, on: window) else { Issue.record("lend refused"); return }
        guard case .success = await start(setup, on: window, requestID: requestID) else { Issue.record("start"); return }
        _ = await start(setup, on: window, requestID: requestID)
        #expect(setup.launcher.launchCount == 1)
        #expect(setup.launcher.lent == [["GEMINI_API_KEY": Self.token]])
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
        #expect(setup.launcher.lent == [["GEMINI_API_KEY": Self.otherToken]])
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

    @Test func ownSignInOnlyStartsWithNoKeyAndRefusesALend() async throws {
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
        #expect(wanted(await start(bare, on: window)) == DaemonAPI.CredentialWanted(runtime: "gemini", offered: false))

        let signedIn = try await setUp(ownSignIn: true)
        guard case .success = await start(signedIn, on: window) else { Issue.record("start"); return }
        #expect(signedIn.launcher.lent == [[:]])
    }


    @Test func theKeyIsWrittenNowhereUnderTheRoot() async throws {
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

    /// What claude-agent-acp 0.81.2 answered a made-up token with (walk/spike.md T009); the
    /// shape any runtime's refusal takes here.
    static let refusal = JSONRPCError(
        code: -32603, message: "Internal error: Failed to authenticate. API Error: 401 OAuth access token is invalid.",
        data: ["errorKind": "authentication_failed"])

    @Test func aRefusedKeyStopsTheAgentSayingSoAndNotStoppedAnswering() async throws {
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
        #expect(notes.contains("Gemini refused the key in Settings. Replace it in Settings ▸ Servers."))
        #expect(!notes.contains { $0.contains("stopped answering") })
        #expect(await setup.core.agent(id)?.endedReason == .signInRefused, "not \"The runtime crashed\"")
    }

    @Test func onlyAnAuthenticationFailureCounts() {
        #expect(DaemonCore.isAuthenticationFailure(Self.refusal))
        #expect(!DaemonCore.isAuthenticationFailure(JSONRPCError(code: -32000, message: "Authentication required")))
        #expect(!DaemonCore.isAuthenticationFailure(JSONRPCError(code: -32603, message: "Internal error: overloaded")))
    }

    // MARK: Claude, relayed or not at all (056)

    private func signInWanted(_ result: Result<JSONValue, JSONRPCError>) -> DaemonAPI.SignInWanted? {
        guard case .failure(let error) = result, error.code == DaemonAPI.Failure.signInWanted,
              let data = error.data else { return nil }
        return try? data.decode(DaemonAPI.SignInWanted.self)
    }

    @Test func claudeWithNoRelayAndNoSignInOfItsOwnSaysTheMacIsNotSignedIn() async throws {
        let setup = try await setUp(ownSignIn: false)
        let window = UUID()
        await offer(setup, on: window)
        let answer = await start(setup, on: window, runtime: "claude")
        #expect(signInWanted(answer) == DaemonAPI.SignInWanted(runtime: "claude", reason: .notSignedIn))
        guard case .failure(let error) = answer else { return }
        #expect(error.message == "Claude on this Mac isn’t signed in with a Claude account.")
        #expect(setup.launcher.launchCount == 0)
        #expect(wanted(answer) == nil, "never a token to paste")
    }

    @Test func claudeWithNoRelayUsesTheServersOwnSignIn() async throws {
        let setup = try await setUp(ownSignIn: true)
        let window = UUID()
        await offer(setup, on: window)
        guard case .success = await start(setup, on: window, runtime: "claude") else { Issue.record("start"); return }
        #expect(setup.launcher.lent == [[:]])
    }

    @Test func ownSignInOnlyStartsClaudeWithNothingEvenWithoutASignIn() async throws {
        let setup = try await setUp(ownSignIn: false)
        let window = UUID()
        await offer(setup, on: window, ownSignInOnly: true)
        guard case .success = await start(setup, on: window, runtime: "claude") else { Issue.record("start"); return }
        #expect(setup.launcher.lent == [[:]])
    }

    @Test func aMacThatCouldNotReadItsSignInSaysSo() async throws {
        let setup = try await setUp(ownSignIn: false)
        let window = UUID()
        _ = await call(setup, DaemonAPI.Method.credentialsOffer,
                       DaemonAPI.CredentialsOffer(runtimes: [], ownSignInOnly: false, notRelayed: ["claude": .unreadable]),
                       on: window)
        let answer = await start(setup, on: window, runtime: "claude")
        #expect(signInWanted(answer)?.reason == .unreadable)
        guard case .failure(let error) = answer else { return }
        #expect(error.message == "Agents couldn’t read Claude’s sign-in on this Mac.")
    }

    // MARK: Gemini's key on this Mac (046, D3)

    /// Made up, in the shape Google issues now.
    static let geminiKey = "AQ." + "Ab8RN6Kfake-LENDTEST-gemini-key-0000000000000000"

    private func lendGemini(_ setup: Setup, on connection: UUID) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.credentialsLend,
                   DaemonAPI.CredentialsLend(runtime: "gemini", secret: Secret(Self.geminiKey)!), on: connection)
    }

    private func startGemini(_ setup: Setup, on connection: UUID) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.agentsStart,
                   DaemonAPI.StartRequest(runtimeID: "gemini", cwd: setup.folder, prompt: "hello", requestID: UUID()),
                   on: connection)
    }

    /// Whether this machine's own login environment already signs Gemini in, which would
    /// make "nothing lent" start anyway, rightly.
    private var personHasAGeminiKey: Bool {
        let own = LoginShellPath.environment()
        return CredentialKind.variables(for: "gemini").contains { !(own[$0] ?? "").isEmpty }
    }

    @Test func theMacsOwnDaemonTakesGeminisKeyAndHandsItOnlyToGemini() async throws {
        let setup = try await setUp(server: false)
        let window = UUID()
        guard case .success = await lendGemini(setup, on: window) else { Issue.record("refused"); return }
        guard case .success = await startGemini(setup, on: window) else { Issue.record("did not start"); return }
        guard case .success = await start(setup, on: window, runtime: "claude") else { Issue.record("Claude did not start"); return }
        // Paired by launch, since a background check may start a runtime of its own too.
        let pairs = zip(setup.launcher.launches.map(\.runtime), setup.launcher.lent)
        #expect(pairs.contains { $0.0 == "gemini" })
        #expect(pairs.contains { $0.0 == "claude" })
        for (runtime, lent) in pairs {
            #expect(lent == (runtime == "gemini" ? ["GEMINI_API_KEY": Self.geminiKey] : [:]),
                    "\(runtime) was lent \(lent.keys.sorted())")
        }
    }

    @Test func itOutlivesTheWindowThatLentIt() async throws {
        let setup = try await setUp(server: false)
        let window = UUID()
        _ = await lendGemini(setup, on: window)
        await setup.core.forgetCredentials(window)
        guard case .success = await startGemini(setup, on: UUID()) else { Issue.record("did not start"); return }
        #expect(setup.launcher.lent.last?["GEMINI_API_KEY"] == Self.geminiKey)
    }

    @Test func aKeyTakenOutOfSettingsIsNoLongerLent() async throws {
        let setup = try await setUp(server: false)
        let window = UUID()
        _ = await lendGemini(setup, on: window)
        _ = await call(setup, DaemonAPI.Method.credentialsOffer,
                       DaemonAPI.CredentialsOffer(runtimes: [], ownSignInOnly: false), on: window)
        let result = await startGemini(setup, on: window)
        if personHasAGeminiKey {
            #expect(setup.launcher.lent.last?.isEmpty == true, "the person's own key, untouched")
        } else {
            guard case .failure(let error) = result else { Issue.record("started with no key"); return }
            #expect(error.code == DaemonAPI.Failure.credentialWanted)
            #expect(error.message == "Gemini needs an API key. Add one in Settings ▸ Agent Runtimes.")
            #expect(wanted(result)?.runtime == "gemini")
        }
    }

    @Test func aLentGeminiKeyTakesOutTheOnesGeminiWouldPrefer() {
        let applied = LentEnvironment.$value.withValue(["GEMINI_API_KEY": Self.geminiKey]) {
            LentEnvironment.applied(to: ["GOOGLE_API_KEY": "theirs", "ANTHROPIC_API_KEY": "claude's", "PATH": "/bin"])
        }
        #expect(applied == ["GEMINI_API_KEY": Self.geminiKey, "ANTHROPIC_API_KEY": "claude's", "PATH": "/bin"])
    }

    // MARK: Gemini on a server (046, US4)

    @Test func aServerLendsGeminiItsKeyForThatRunOnly() async throws {
        let setup = try await setUp(server: true, ownSignIn: false)
        let window = UUID()
        _ = await call(setup, DaemonAPI.Method.credentialsOffer,
                       DaemonAPI.CredentialsOffer(runtimes: ["claude", "gemini"], ownSignInOnly: false), on: window)
        // Nothing lent yet: the start is refused before anything runs, and asks.
        let first = await startGemini(setup, on: window)
        #expect(wanted(first)?.runtime == "gemini")
        if case .failure(let error) = first { #expect(error.message == "Gemini on this server needs a key.") }
        #expect(!setup.launcher.launches.contains { $0.runtime == "gemini" })

        guard case .success = await lendGemini(setup, on: window) else { Issue.record("refused"); return }
        guard case .success = await startGemini(setup, on: window) else { Issue.record("did not start"); return }
        let pairs = zip(setup.launcher.launches.map(\.runtime), setup.launcher.lent)
        #expect(pairs.contains { $0.0 == "gemini" && $0.1 == ["GEMINI_API_KEY": Self.geminiKey] })
    }

    @Test func aKeyForOneRuntimeIsNotTakenForAnother() async throws {
        let setup = try await setUp(server: true)
        let window = UUID()
        _ = await call(setup, DaemonAPI.Method.credentialsOffer,
                       DaemonAPI.CredentialsOffer(runtimes: ["claude", "gemini"], ownSignInOnly: false), on: window)
        let result = await call(setup, DaemonAPI.Method.credentialsLend,
                                DaemonAPI.CredentialsLend(runtime: "claude", secret: Secret(Self.geminiKey)!), on: window)
        guard case .failure = result else { Issue.record("a Gemini key was taken for Claude"); return }
    }
}
