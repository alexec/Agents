import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// US2 of 052: the pool is the person's to set, whole, and it stays set.
@Suite("Setting the pool", .timeLimit(.minutes(1)))
struct PoolSetTests {
    private let claude = PoolEntry(runtimeID: "claude", payment: .allowance(label: "Max plan"))
    private let codex = PoolEntry(runtimeID: "codex", payment: .allowance(label: "ChatGPT plan"))
    private let copilot = PoolEntry(runtimeID: "copilot", payment: .allowance(label: nil))

    private func core(_ scripts: [FakeACPAgent.Script] = [], root: URL? = nil) throws -> (DaemonCore, URL, FakeLauncher) {
        let root = root ?? URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PoolSet-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let locations = StoreLocations(root: root)
        var discovery = RuntimeDiscovery.findsEverything
        let current = locations.tools.appendingPathComponent("codex/current", isDirectory: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: current.appendingPathComponent("ok"))
        discovery.macToolsHome = locations.tools.path
        let launcher = FakeLauncher(script: FakeACPAgent.Script(), then: scripts)
        let core = DaemonCore(store: try AgentStore(locations: locations), locations: locations,
                              discovery: discovery, launcher: launcher)
        return (core, work, launcher)
    }

    private func refusal(_ core: DaemonCore, _ pool: PoolSettings) async -> String? {
        do {
            _ = try await core.setPool(pool)
            return nil
        } catch let error as JSONRPCError {
            #expect(error.code == -32602)
            return error.message
        } catch {
            return "\(error)"
        }
    }

    @Test func eachRefusalSaysWhy() async throws {
        let (core, _, _) = try core()
        let keyAsPlan = PoolEntry(runtimeID: "gemini", payment: .allowance(label: nil),
                                  credentialRef: CredentialKind.geminiAPIKey.rawValue)
        #expect(await refusal(core, PoolSettings(isOn: true, entries: [keyAsPlan]))
                == "Gemini on an API key is paid by use, so it cannot be an allowance.")
        let oldCodexKey = PoolEntry(runtimeID: "codex", payment: .prepaid(amount: nil, expires: nil), credentialRef: "openAIAPIKey")
        #expect(await refusal(core, PoolSettings(isOn: true, entries: [oldCodexKey]))
                == "Codex has no key this Mac lends, so it joins the pool on its own sign-in.")
        let gemini = PoolEntry(runtimeID: "gemini", payment: .allowance(label: nil))
        #expect(await refusal(core, PoolSettings(isOn: true, entries: [gemini]))?
            .hasSuffix("is paid by use, so it cannot be an allowance.") == true)
        let nothing = PoolEntry(runtimeID: "gemini", payment: .prepaid(amount: Cost(amount: 0, currency: "USD"), expires: nil),
                                credentialRef: CredentialKind.geminiAPIKey.rawValue)
        #expect(await refusal(core, PoolSettings(isOn: true, entries: [nothing]))?
            .hasSuffix("has to be more than nothing.") == true)
        #expect(await refusal(core, PoolSettings(isOn: true, entries: [PoolEntry(runtimeID: "nope", payment: .allowance(label: nil))]))
                == "There is no runtime called nope.")
        let fast = Level(name: "Fast", cells: ["claude": Cell(model: "haiku")])
        let quick = Level(name: "Quick", cells: ["claude": Cell(model: "haiku")])
        #expect(await refusal(core, PoolSettings(isOn: true, entries: [claude], levels: [fast, quick]))?
            .contains("it is in both Fast and Quick") == true)
        // Nothing refused was kept.
        #expect(await core.poolStatus().settings.entries.isEmpty)
    }

    @Test func theWholePoolIsReplacedAndTheWindowsAreTold() async throws {
        let (core, _, _) = try core()
        let heard = PoolsHeard()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.poolChanged,
                  let params, let status = try? JSONDecoder().decode(PoolStatus.self, from: JSONEncoder().encode(params))
            else { return }
            heard.append(status.settings.entries.map(\.runtimeID))
        }
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex, copilot]))
        let status = try await core.setPool(PoolSettings(isOn: true, entries: [copilot, claude]))
        #expect(status.settings.entries.map(\.runtimeID) == ["copilot", "claude"])
        #expect(status.rows.map(\.entry.runtimeID) == ["copilot", "claude"])
        await eventually("both changes were broadcast") { heard.all.count >= 2 }
        #expect(heard.all.last == ["copilot", "claude"])
    }

    @Test func onlyTheOwnerMaySetIt() {
        #expect(!ConnectionRole.device.allows(DaemonAPI.Method.poolSet))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.poolState))
        #expect(ConnectionRole.device.allows(DaemonAPI.Method.poolMarkAvailable))
    }

    @Test func itIsStillThereAfterARestart() async throws {
        let (first, work, _) = try core()
        let prepaid = PoolEntry(runtimeID: "gemini", payment: .prepaid(amount: Cost(amount: 10, currency: "USD"), expires: nil),
                                credentialRef: CredentialKind.geminiAPIKey.rawValue)
        _ = try await first.setPool(PoolSettings(isOn: true, entries: [claude, prepaid]))
        let root = work.deletingLastPathComponent()
        let (second, _, _) = try core(root: root)
        let settings = await second.poolStatus().settings
        #expect(settings.isOn)
        #expect(settings.entries == [claude, prepaid])
    }

    @Test func aSignedOutEntryStaysAndIsSkipped() async throws {
        var spent = FakeACPAgent.Script()
        spent.promptResultMeta = try SessionFailureDecodingTests.fixture("quota-exhausted")
        let (core, work, _) = try core([spent])
        _ = try await core.setPool(PoolSettings(isOn: true, entries: [claude, codex, copilot]))
        await core.markNeedsSignIn(runtimeID: "codex")
        let status = await core.poolStatus()
        #expect(status.rows.map(\.entry.runtimeID) == ["claude", "codex", "copilot"])
        #expect(status.rows.first { $0.entry.runtimeID == "codex" }?.unusable == "not signed in")

        let id = try await core.start(.init(runtimeID: "claude", cwd: work, prompt: "go"))
        await eventually("it moved past Codex") { await core.agent(id)?.runtimeID == "copilot" }
    }
}

/// What the windows were told. The broadcaster is called from wherever the daemon is.
private final class PoolsHeard: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [[String]] = []
    func append(_ value: [String]) { lock.lock(); seen.append(value); lock.unlock() }
    var all: [[String]] { lock.lock(); defer { lock.unlock() }; return seen }
}
