import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// `runtimes/install` on the daemon (048): one install per runtime, its state on
/// `runtime/changed` and in `runtimes/list`, and refused where it does not belong.
@Suite("Installing a runtime through the daemon", .timeLimit(.minutes(1)))
struct RuntimeInstallDispatchTests {
    /// An installer that counts and waits to be let go, then says what it was told to.
    private final class Gated: RuntimeInstalling, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var opened = false
        let result: RuntimeAvailability

        init(result: RuntimeAvailability) { self.result = result }

        var count: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func open() {
            lock.lock()
            opened = true
            let waiting = gate
            gate = nil
            lock.unlock()
            waiting?.resume()
        }

        func recipe(for runtime: Runtime) -> RuntimeInstall? { runtime.install }

        func install(_ runtime: Runtime, progress: @escaping @Sendable (String) -> Void) async -> RuntimeAvailability {
            lock.withLock { calls += 1 }
            progress("Downloading")
            await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                lock.lock()
                if opened { lock.unlock(); done.resume() } else { gate = done; lock.unlock() }
            }
            return result
        }
    }

    private final class Heard: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [RuntimeStatus] = []
        func add(_ status: RuntimeStatus) { lock.lock(); statuses.append(status); lock.unlock() }
        var all: [RuntimeStatus] { lock.lock(); defer { lock.unlock() }; return statuses }
    }

    private func core(installer: (any RuntimeInstalling)?) throws -> (DaemonCore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsInstallTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        let nothing = RuntimeDiscovery(searchPaths: ["/nowhere"]) { _ in false }
        return (DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                           discovery: nothing, installer: installer), root)
    }

    private func install(_ core: DaemonCore, _ id: String) async -> Result<JSONValue, JSONRPCError> {
        await core.handle(method: DaemonAPI.Method.runtimesInstall,
                          params: try? JSONValue.encoding(DaemonAPI.RuntimeRequest(runtimeID: id)), from: .mac)
    }

    @Test func anUnknownRuntimeIsNotFound() async throws {
        let (core, root) = try core(installer: Gated(result: .installFailed(reason: "x")))
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .failure(let error) = await install(core, "nope") else { Issue.record("installed"); return }
        #expect(error.code == DaemonAPI.Failure.runtimeNotFound)
    }

    @Test func aServerRefuses() async throws {
        let (core, root) = try core(installer: nil)
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .failure(let error) = await install(core, "grok") else { Issue.record("installed"); return }
        #expect(error.code == DaemonAPI.Failure.notSupported)
        #expect(await core.runtimeStatuses().allSatisfy { $0.runtime.install == nil }, "no button is offered")
    }

    /// It runs a vendor's script, so only the app's own window may ask: an agent's
    /// helper and a stranger on the socket are turned away before dispatch.
    @Test func onlyTheWindowMayAsk() {
        #expect(ConnectionRole.control.allows(DaemonAPI.Method.runtimesInstall))
        #expect(!ConnectionRole.agent.allows(DaemonAPI.Method.runtimesInstall))
        #expect(!ConnectionRole.stranger.allows(DaemonAPI.Method.runtimesInstall))
    }

    @Test func aPhoneIsRefused() async throws {
        let (core, root) = try core(installer: Gated(result: .installFailed(reason: "x")))
        defer { try? FileManager.default.removeItem(at: root) }
        let result = await core.handle(method: DaemonAPI.Method.runtimesInstall,
                                       params: try JSONValue.encoding(DaemonAPI.RuntimeRequest(runtimeID: "grok")),
                                       from: .device(UUID()))
        guard case .failure(let error) = result else { Issue.record("installed"); return }
        #expect(error.code == DaemonAPI.Failure.notSupported)
    }

    /// An outdated toolset (047): available, marked outdated in the list, and
    /// `runtimes/install` then installs rather than answering "already here".
    @Test func anOutdatedToolsetIsListedAsSuchAndUpdateInstalls() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsInstallTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = root.appendingPathComponent("tools", isDirectory: true)
        let set = tools.appendingPathComponent("claude/old", isDirectory: true)
        try FileManager.default.createDirectory(at: set.appendingPathComponent("bin"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: set.appendingPathComponent("bin/npx").path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: set.appendingPathComponent("ok").path, contents: Data())
        try FileManager.default.createSymbolicLink(atPath: tools.appendingPathComponent("claude/current").path,
                                                   withDestinationPath: "old")
        var discovery = RuntimeDiscovery(searchPaths: ["/nowhere"])
        discovery.macToolsHome = tools.path
        discovery.bundledToolsetIDs = ["claude": "new"]
        let gated = Gated(result: .available(path: "\(tools.path)/claude/current/bin/npx", supportsResume: false))
        gated.open()
        let locations = StoreLocations(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, installer: gated)

        let listed = await core.runtimeStatuses().first { $0.id == "claude" }
        #expect(listed?.availability.isAvailable == true)
        #expect(listed?.outdated == true)
        #expect(await core.runtimeStatuses().first { $0.id == "grok" }?.outdated == false)

        _ = await install(core, "claude")
        await core.waitForInstall("claude")
        #expect(gated.count == 1, "Update installs even though Claude is here")
    }

    /// Starting a runtime while it is installed, or after its install failed, says which
    /// (047, FR-003), not "not installed".
    @Test func startingDuringOrAfterAnInstallSaysSo() async throws {
        let gated = Gated(result: .installFailed(reason: "Couldn’t reach the internet to download Grok."))
        let (core, root) = try core(installer: gated)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(await core.notYetInstalled(RuntimeCatalog.grok) == nil)
        _ = await install(core, "grok")
        do {
            _ = try await core.handshakeOnly(runtimeID: "grok")
            Issue.record("started")
        } catch let error as JSONRPCError {
            #expect(error.message == "Grok is still being installed. Try again when it is.")
        }
        gated.open()
        await core.waitForInstall("grok")
        #expect(await core.notYetInstalled(RuntimeCatalog.grok)
                == "Grok isn’t installed: Couldn’t reach the internet to download Grok.")
    }

    /// A status from a daemon before 047 is past the cut-off (#58).
    @Test func aStatusFromBefore047DoesNotRead() throws {
        let status = RuntimeStatus(runtime: RuntimeCatalog.claude, availability: .missing(lookedIn: []))
        var json = try JSONEncoder().encode(status)
        var object = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        object["outdated"] = nil
        json = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(RuntimeStatus.self, from: json) }
    }

    @Test func twoCallsAtOnceAreOneInstall() async throws {
        let gated = Gated(result: .installFailed(reason: "The installer failed."))
        let (core, root) = try core(installer: gated)
        defer { try? FileManager.default.removeItem(at: root) }
        let heard = Heard()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.runtimeChanged,
                  let status = try? params?.decode(RuntimeStatus.self) else { return }
            heard.add(status)
        }

        async let first = install(core, "grok")
        async let second = install(core, "grok")
        for result in await [first, second] {
            let status = try result.get().decode(RuntimeStatus.self)
            #expect(status.availability.isInstalling)
        }
        #expect(await eventually("the installer was started") { gated.count == 1 })
        #expect(await eventually("the step was told") {
            heard.all.contains { $0.availability == .installing(progress: "Downloading") }
        })
        let listed = await core.runtimeStatuses().first { $0.id == "grok" }
        #expect(listed?.availability.isInstalling == true)

        gated.open()
        await core.waitForInstall("grok")
        #expect(gated.count == 1)
        #expect(await core.runtimeStatuses().first { $0.id == "grok" }?.availability
                == .installFailed(reason: "The installer failed."))
        #expect(await eventually("the failure went out") {
            heard.all.last?.availability == .installFailed(reason: "The installer failed.")
        })
    }

    @Test func anInstallThatWorksLeavesNothingOverTheList() async throws {
        let gated = Gated(result: .available(path: "/somewhere/grok", supportsResume: false))
        gated.open()
        let (core, root) = try core(installer: gated)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await install(core, "grok")
        await core.waitForInstall("grok")
        // Discovery here finds nothing, so what the list shows is discovery's own answer.
        #expect(await core.runtimeStatuses().first { $0.id == "grok" }?.availability
                == .missing(lookedIn: ["/nowhere"]))
    }

    // MARK: Starting on a runtime that is not ready (046, FR-003)

    private func startGemini(_ core: DaemonCore, in root: URL) async -> JSONRPCError? {
        do {
            _ = try await core.start(.init(runtimeID: "gemini", cwd: root, prompt: "go"))
            return nil
        } catch let error as JSONRPCError {
            return error
        } catch {
            return nil
        }
    }

    @Test func startingOneThatIsNotHereSaysWhereToInstallIt() async throws {
        let (core, root) = try core(installer: Gated(result: .installFailed(reason: "x")))
        defer { try? FileManager.default.removeItem(at: root) }
        let error = try #require(await startGemini(core, in: root))
        #expect(error.code == DaemonAPI.Failure.runtimeNotFound)
        #expect(error.message == "Gemini isn’t on this Mac. Install it from Settings ▸ Agent Runtimes.")
    }

    @Test func startingOneBeingInstalledSaysSo() async throws {
        let gated = Gated(result: .installFailed(reason: "Couldn’t reach the internet to download Gemini."))
        let (core, root) = try core(installer: gated)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = await install(core, "gemini")
        let during = try #require(await startGemini(core, in: root))
        #expect(during.message.hasPrefix("Gemini is still being installed."))

        gated.open()
        await core.waitForInstall("gemini")
        let after = try #require(await startGemini(core, in: root))
        #expect(after.message == "Gemini isn’t installed: Couldn’t reach the internet to download Gemini.")
    }
}
