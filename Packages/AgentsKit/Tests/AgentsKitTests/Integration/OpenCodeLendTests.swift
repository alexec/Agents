import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server's OpenCode borrowing the Mac's sign-in (049 T032, D7, FR-022): asked for at a
/// start, lent on that connection only, for OpenCode's runs only, in the environment only.
/// Against the real daemon core with the fake launcher, driven through `handle`.
@Suite("Lending OpenCode the Mac's sign-in on a server")
struct OpenCodeLendTests {
    static let lentText = #"{"anthropic":{"key":"sk-ant-FAKE-LEND-7777","type":"api"}}"#
    static let variable = "OPENCODE_AUTH_CONTENT"

    struct Setup {
        let core: DaemonCore
        let launcher: FakeLauncher
        let locations: StoreLocations
        let folder: URL
    }

    private func setUp(server: Bool = true, own: String? = nil,
                       script: FakeACPAgent.Script = .init()) async throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oc-lend-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launcher = FakeLauncher(script: script)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        await core.setExitsWhenIdle(!server)
        await core.setHasOwnSignIn { _ in true }
        await core.setOwnSignInFile { _ in own.map { Data($0.utf8) } }
        return Setup(core: core, launcher: launcher, locations: locations, folder: folder)
    }

    private func call<T: Encodable>(_ setup: Setup, _ method: String, _ params: T, on connection: UUID)
        async -> Result<JSONValue, JSONRPCError> {
        await setup.core.handle(method: method, params: try? JSONValue.encoding(params), connection: connection)
    }

    private func offer(_ setup: Setup, on connection: UUID, signIns: [String]? = ["opencode"],
                       ownSignInOnly: Bool = false) async {
        _ = await call(setup, DaemonAPI.Method.credentialsOffer,
                       DaemonAPI.CredentialsOffer(runtimes: [], ownSignInOnly: ownSignInOnly, signIns: signIns),
                       on: connection)
    }

    private func lend(_ setup: Setup, _ text: String?, on connection: UUID) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.credentialsLendSignIn,
                   DaemonAPI.SignInLend(runtime: "opencode", content: text.map { LentSignInContent($0, providers: 1) }),
                   on: connection)
    }

    private func start(_ setup: Setup, on connection: UUID, runtime: String = "opencode",
                       requestID: UUID = UUID()) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.agentsStart,
                   DaemonAPI.StartRequest(runtimeID: runtime, cwd: setup.folder, prompt: "hello", requestID: requestID),
                   on: connection)
    }

    private func wanted(_ result: Result<JSONValue, JSONRPCError>) -> DaemonAPI.CredentialWanted? {
        guard case .failure(let error) = result, error.code == DaemonAPI.Failure.credentialWanted,
              let data = error.data else { return nil }
        return try? data.decode(DaemonAPI.CredentialWanted.self)
    }

    @Test func aStartAsksThenRunsExactlyOnceWithTheMacsSignInInItsEnvironment() async throws {
        let setup = try await setUp()
        let window = UUID(), requestID = UUID()
        await offer(setup, on: window)
        #expect(wanted(await start(setup, on: window, requestID: requestID))
                == DaemonAPI.CredentialWanted(runtime: "opencode", offered: true))
        #expect(setup.launcher.launchCount == 0)
        guard case .success = await lend(setup, Self.lentText, on: window) else { Issue.record("lend refused"); return }
        guard case .success = await start(setup, on: window, requestID: requestID) else { Issue.record("start"); return }
        #expect(setup.launcher.launchCount == 1)
        #expect(setup.launcher.lent == [[Self.variable: Self.lentText]])
    }

    @Test func theServersOwnKeysStayUnderTheLentOnes() async throws {
        let setup = try await setUp(own: #"{"groq":{"type":"api","key":"gsk-FAKE-own"},"x":{"type":"oauth","refresh":"r"}}"#)
        let window = UUID()
        await offer(setup, on: window)
        _ = await lend(setup, Self.lentText, on: window)
        _ = await start(setup, on: window)
        let given = try #require(setup.launcher.lent.first?[Self.variable])
        #expect(given.contains("sk-ant-FAKE-LEND-7777") && given.contains("gsk-FAKE-own"))
        #expect(!given.contains("oauth"), "a rotating sign-in of the server's would write the Mac's keys back to disk")
    }

    @Test func aMacWithNothingToLendStartsWithNothingLent() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window)
        guard case .success = await lend(setup, nil, on: window) else { Issue.record("lend refused"); return }
        guard case .success = await start(setup, on: window) else { Issue.record("start"); return }
        #expect(setup.launcher.lent == [[:]])
    }

    @Test func aWindowThatOffersNoSignInIsNotAskedAndStartsAtOnce() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window, signIns: nil)
        guard case .success = await start(setup, on: window) else { Issue.record("asked"); return }
        #expect(setup.launcher.lent == [[:]])
        guard case .failure(let error) = await lend(setup, Self.lentText, on: window) else {
            Issue.record("took a lend it was not offered"); return
        }
        #expect(error.code == DaemonAPI.Failure.notOffered)
    }

    @Test func ownSignInOnlyLendsNothingAndRefusesALend() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window, ownSignInOnly: true)
        guard case .failure(let error) = await lend(setup, Self.lentText, on: window) else {
            Issue.record("took a lend"); return
        }
        #expect(error.code == DaemonAPI.Failure.notOffered)
        guard case .success = await start(setup, on: window) else { Issue.record("start"); return }
        #expect(setup.launcher.lent == [[:]])
    }

    @Test func itNeverReachesAnotherRuntimesProcess() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window)
        _ = await lend(setup, Self.lentText, on: window)
        for runtime in RuntimeCatalog.builtIn.map(\.id) where runtime != "opencode" {
            _ = await start(setup, on: window, runtime: runtime)
        }
        #expect(setup.launcher.launchCount > 0)
        #expect(!setup.launcher.lent.contains { $0.keys.contains(Self.variable) })
    }

    @Test func aClosedConnectionTakesItsLendWithItAndAnotherWindowsIsItsOwn() async throws {
        let setup = try await setUp()
        let first = UUID(), second = UUID()
        await offer(setup, on: first)
        await offer(setup, on: second)
        _ = await lend(setup, Self.lentText, on: first)
        #expect(wanted(await start(setup, on: second))?.offered == true)
        await setup.core.connectionEnded(first)
        #expect(await setup.core.lentSignIns.isEmpty)
    }

    @Test func thisMacsOwnDaemonTakesNoLendAndItsOpenCodeNeverGetsTheVariable() async throws {
        let setup = try await setUp(server: false)
        let window = UUID()
        await offer(setup, on: window)
        guard case .failure(let error) = await lend(setup, Self.lentText, on: window) else {
            Issue.record("the Mac's daemon took a lend"); return
        }
        #expect(error.code == DaemonAPI.Failure.notAServer)
        // A stray one in the daemon's own environment is taken out, on the Mac and on a server.
        let policy = ToolPolicyCatalog.policy(for: "opencode")
        for onServer in [false, true] {
            let environment = ProcessSessionLauncher.environment(for: policy, locations: setup.locations,
                                                     onto: [Self.variable: "stray", "PATH": "/usr/bin"], onServer: onServer)
            #expect(environment[Self.variable] == nil)
        }
    }

    @Test func theLentTextIsWrittenNowhereUnderTheRoot() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offer(setup, on: window)
        _ = await lend(setup, Self.lentText, on: window)
        _ = await start(setup, on: window)
        let files = FileManager.default.enumerator(at: setup.locations.root, includingPropertiesForKeys: nil)
        while let file = files?.nextObject() as? URL {
            guard let data = try? Data(contentsOf: file) else { continue }
            #expect(!String(decoding: data, as: UTF8.self).contains("sk-ant-FAKE-LEND-7777"), "\(file.path)")
        }
    }

    /// OpenCode 1.18.33's words for a key its provider refused (research R6).
    static let refusal = JSONRPCError(code: -32603, message: "Internal error: API key is invalid.",
                                      data: ["errorName": "APIError"])

    @Test func aRefusedLentKeySaysSoAndNamesTheCommandOnTheMac() async throws {
        let setup = try await setUp(script: .init(promptError: Self.refusal))
        let window = UUID()
        await offer(setup, on: window)
        _ = await lend(setup, Self.lentText, on: window)
        guard case .success(let made) = await start(setup, on: window),
              let id = made.stringValue.flatMap(UUID.init(uuidString:)) else { Issue.record("start"); return }
        var notes: [String] = []
        for _ in 0..<50 {
            notes = try await setup.core.transcript(.init(agentID: id, before: nil, limit: 500)).entries.compactMap {
                if case .runtimeNote(let text) = $0.kind { return text } else { return nil }
            }
            if notes.contains(where: { $0.contains("refused") }) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(notes.contains("A provider refused the key this Mac lent OpenCode. Sign in to it again on the Mac with opencode auth login, then send again."))
        #expect(!notes.contains { $0.contains("stopped answering") })
        #expect(await setup.core.agent(id)?.endedReason == .signInRefused)
    }
}
