import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// A server's daemon starting runtimes whose sign-in the Mac relays (047 Codex, 056 Claude),
/// against the real daemon core with the fake launcher, driven through `handle` as the socket
/// drives it.
@Suite("Relayed sign-ins on a server")
struct ClaudeRelayTests {
    static let standIn = "sk-ant-oat01-agents-relay-standin"

    struct Setup {
        let core: DaemonCore
        let launcher: FakeLauncher
        let locations: StoreLocations
        let folder: URL
    }

    private func setUp(ownSignIn: Bool = false) async throws -> Setup {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relayed-\(UUID().uuidString)")
        let locations = StoreLocations(root: root)
        try locations.createDirectories()
        let folder = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let launcher = FakeLauncher()
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: .findsEverything, launcher: launcher)
        await core.loadFromDisk()
        await core.setExitsWhenIdle(false)
        await core.setHasOwnSignIn { _ in ownSignIn }
        return Setup(core: core, launcher: launcher, locations: locations, folder: folder)
    }

    private func call<T: Encodable>(_ setup: Setup, _ method: String, _ params: T, on connection: UUID)
        async -> Result<JSONValue, JSONRPCError> {
        await setup.core.handle(method: method, params: try? JSONValue.encoding(params), connection: connection)
    }

    private func offerRelay(_ setup: Setup, _ runtime: String, standIn: String, on connection: UUID) async {
        let socket = setup.locations.root.appendingPathComponent("relay-\(runtime).sock").path
        let result = await call(setup, DaemonAPI.Method.relayOffer,
                                DaemonAPI.RelayOffer(runtime: runtime, socketPath: socket,
                                                     caCertificate: "-----BEGIN CERTIFICATE-----\nCA\n-----END CERTIFICATE-----\n",
                                                     standIn: standIn), on: connection)
        if case .failure(let error) = result { Issue.record("relay/offer failed: \(error.message)") }
    }

    private func start(_ setup: Setup, _ runtime: String, on connection: UUID) async -> Result<JSONValue, JSONRPCError> {
        await call(setup, DaemonAPI.Method.agentsStart,
                   DaemonAPI.StartRequest(runtimeID: runtime, cwd: setup.folder, prompt: "hello", requestID: UUID()),
                   on: connection)
    }

    /// Claude's relay is variables only: the gate's port, the stand-in, the CA to trust.
    @Test func claudeStartsPointedAtTheGateWithTheStandIn() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offerRelay(setup, "claude", standIn: Self.standIn, on: window)
        guard case .success = await start(setup, "claude", on: window) else { Issue.record("did not start"); return }
        let lent = try #require(setup.launcher.lent.last)
        let base = try #require(lent["ANTHROPIC_BASE_URL"])
        #expect(base.hasPrefix("https://127.0.0.1:") && base != "https://127.0.0.1:0")
        #expect(lent["CLAUDE_CODE_OAUTH_TOKEN"] == Self.standIn)
        let ca = try #require(lent["NODE_EXTRA_CA_CERTS"])
        #expect(ca.hasSuffix("runtimes/claude-relay-ca.pem"))
        let mode = try FileManager.default.attributesOfItem(atPath: ca)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(lent["CODEX_HOME"] == nil, "no home of Codex's shape for Claude")
    }

    /// Two runtimes relayed on one connection keep their own offers; a second offer for
    /// the same runtime replaces the first.
    @Test func eachRuntimeKeepsItsOwnOffer() async throws {
        let setup = try await setUp()
        let window = UUID()
        await offerRelay(setup, "codex", standIn: #"{"auth_mode":"chatgpt"}"#, on: window)
        await offerRelay(setup, "claude", standIn: "sk-ant-oat01-first-standin", on: window)
        await offerRelay(setup, "claude", standIn: Self.standIn, on: window)
        #expect(await setup.core.relayOffers[window]?.keys.sorted() == ["claude", "codex"])
        #expect(await setup.core.relayOffers[window]?["claude"]?.standIn == Self.standIn)

        _ = await start(setup, "codex", on: window)
        let codex = try #require(setup.launcher.lent.last)
        #expect(codex["CODEX_HOME"] != nil && codex["CODEX_CA_CERTIFICATE"] != nil)
        #expect(codex["ANTHROPIC_BASE_URL"] == nil)
    }

    /// A workflow firing has no connection: any window's offer serves.
    @Test func aStartWithNoConnectionUsesAnyWindowsRelay() async throws {
        let setup = try await setUp()
        await offerRelay(setup, "claude", standIn: Self.standIn, on: UUID())
        let offer = await RequestConnection.$current.withValue(nil) { await setup.core.relayOffer(for: "claude") }
        #expect(offer?.standIn == Self.standIn)
    }
}
