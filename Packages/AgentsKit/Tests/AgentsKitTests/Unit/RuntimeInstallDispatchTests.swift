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
}
