import Foundation
import Testing
@testable import AgentsKit
@testable import AgentsKitCore

/// What happens when an agent asks the app to do something.
///
/// Only Grok does this today, and only once the app advertises that it can, so the fake
/// agent is how it is tested. The rule being tested is the promise: whatever we said we
/// would serve, we serve, because a runtime that takes us up on it has no fallback.
/// Collects what the daemon told the windows, for the tests that care about that
/// rather than about what the daemon is holding.
final class Heard: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [String] = []

    func add(_ chunk: String) {
        lock.lock(); defer { lock.unlock() }
        chunks.append(chunk)
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return chunks.joined()
    }
}

@Suite("Serving an agent", .timeLimit(.minutes(1)))
struct ServingTests {
    private let serving = ACP.ClientCapabilities(readTextFile: true, writeTextFile: true,
                                                 terminal: true, elicitationForm: true,
                                                 elicitationURL: true)

    private func temporary() throws -> (StoreLocations, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("AgentsServingTests-\(UUID().uuidString)", isDirectory: true)
        let work = root.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        return (StoreLocations(root: root), work.resolvingSymlinksInPath())
    }

    private func core(_ launcher: FakeLauncher, locations: StoreLocations) throws -> DaemonCore {
        DaemonCore(store: try AgentStore(locations: locations),
                   locations: locations,
                   discovery: .findsEverything,
                   launcher: launcher)
    }

    // MARK: Files

    @Test func aReadIsServedAndRecordedWithoutAsking() async throws {
        // Grok issues several reads for one small edit. A question per read would make
        // the app unusable, and a read changes nothing.
        let (locations, work) = try temporary()
        try "inside".write(to: work.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.readTextFile,
                                  ["path": .string(work.appending(path: "notes.txt").path)])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "read it"))

        let answer = await eventuallySome("an answer to the read") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.readTextFile)
        }
        guard case .success(let result)? = answer else {
            Issue.record("the read was not served: \(String(describing: answer))")
            return
        }
        #expect(result["content"]?.stringValue == "inside")

        // The record is not the answer. The reply goes straight back down the
        // transport while the entry has to be drained off the event stream and
        // appended, so the agent can have been served with nothing written down yet.
        @Sendable func servedSoFar() async -> [ServedRequest] {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.compactMap { entry -> ServedRequest? in
                if case .servedRequest(let request) = entry.kind { return request } else { return nil }
            } ?? []
        }
        await eventually("the read reached the record") { await servedSoFar().count == 1 }

        let served = await servedSoFar()
        #expect(served.count == 1, "recorded, so the user can see what was touched")
        #expect(served.first?.outcome == .served)
    }

    @Test func aReadOutsideTheAgentsFoldersIsRefused() async throws {
        let (locations, work) = try temporary()
        let elsewhere = try temporary().1.appending(path: "secret.txt")
        try "no".write(to: elsewhere, atomically: true, encoding: .utf8)
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.readTextFile, ["path": .string(elsewhere.path)])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "read it"))

        let answer = await eventuallySome("an answer to the read") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.readTextFile)
        }
        guard case .failure(let error)? = answer else {
            Issue.record("a read outside the folders must be refused")
            return
        }
        #expect(error.message.contains("Outside this agent's folders"))
    }

    @Test func aWriteGoesThroughThePermissionQuestion() async throws {
        let (locations, work) = try temporary()
        let target = work.appending(path: "written.txt")
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.writeTextFile,
                                  ["path": .string(target.path), "content": "from the agent"])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "write it"))
        await eventually("the write raised a question") {
            await core.pendingPermissionRequests().isEmpty == false
        }

        // It is waiting on us, with the change in the question.
        let pending = await core.pendingPermissionRequests()
        #expect(pending.count == 1)
        #expect(pending.first?.toolCall.diffs.first?.newText == "from the agent")
        #expect(FileManager.default.fileExists(atPath: target.path) == false, "nothing yet")

        guard let request = pending.first else { return }
        try await core.answerPermission(.init(permissionID: request.id, optionID: "allow_once"))
        await eventually("the file was written") {
            (try? String(contentsOf: target, encoding: .utf8)) == "from the agent"
        }
        // And written down, which is a beat later again: the file is written while the
        // request is served, and the entry is appended from the event stream after.
        @Sendable func writeIsOnTheRecord() async -> Bool {
            let page = try? await core.transcript(.init(agentID: id))
            return page?.entries.contains { entry in
                if case .servedRequest(let request) = entry.kind, case .writeFile = request.kind { return true }
                return false
            } == true
        }
        await eventually("the write reached the record") { await writeIsOnTheRecord() }

        #expect(try String(contentsOf: target, encoding: .utf8) == "from the agent")
        #expect(await writeIsOnTheRecord())
    }

    @Test func aRefusedWriteLeavesTheFileAloneAndTellsTheAgent() async throws {
        let (locations, work) = try temporary()
        let target = work.appending(path: "kept.txt")
        try "original".write(to: target, atomically: true, encoding: .utf8)
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.writeTextFile,
                                  ["path": .string(target.path), "content": "changed"])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "write it"))
        await eventually("the write raised a question") {
            await core.pendingPermissionRequests().isEmpty == false
        }
        guard let request = await core.pendingPermissionRequests().first else {
            Issue.record("expected to be asked")
            return
        }
        try await core.answerPermission(.init(permissionID: request.id, optionID: "reject_once"))

        let answer = await eventuallySome("the refusal reached the agent") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.writeTextFile)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "original")
        guard case .failure? = answer else {
            Issue.record("the agent must be told it was refused")
            return
        }
    }

    @Test func nothingIsServedWhenWeDidNotSayWeWould() async throws {
        // The capability flag is the promise. With it off, a runtime falls back to its
        // own tools, which is what Grok does today.
        let (locations, work) = try temporary()
        try "inside".write(to: work.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.readTextFile,
                                  ["path": .string(work.appending(path: "notes.txt").path)])]
        let launcher = FakeLauncher(script: script, capabilities: .none)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "read it"))

        let answer = await eventuallySome("an answer to the read") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.readTextFile)
        }
        guard case .failure(let error)? = answer else {
            Issue.record("expected a refusal")
            return
        }
        #expect(error.isMethodNotFound, "declined loudly, so the runtime can fall back")
    }

    @Test func aRuntimesOwnBlockingMethodIsDeclinedAtOnceRatherThanLeftOpen() async throws {
        // Cursor's `cursor/create_plan` is a request, not a notification, so it waits for
        // an answer. Answered, the turn runs to its end; unanswered, it does not finish at
        // all. So the refusal is not a fallback here, it is what lets the turn complete.
        // The method name is data: nothing in the client knows which runtime sent it.
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [("cursor/create_plan",
                                  ["name": "A plan", "plan": "# Do the thing"])]
        let launcher = FakeLauncher(script: script, capabilities: .app)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "plan it"))

        let answer = await eventuallySome("an answer to cursor/create_plan") {
            await launcher.lastAgent?.answer(to: "cursor/create_plan")
        }
        guard case .failure(let error)? = answer else {
            Issue.record("a blocking request must be answered, or the turn never ends")
            return
        }
        #expect(error.isMethodNotFound)
    }

    // MARK: Terminals

    @Test func aCommandRunsAndItsOutputComesBack() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [
            (ACP.ClientMethod.createTerminal, ["command": "echo", "args": ["probe-ran"],
                                               "cwd": .string(work.path)]),
        ]
        // The turn stays open on a question. A real agent waits for its command's
        // output before ending a turn; ours would otherwise end while echo is still
        // being read, and the runtime is let go the moment a turn ends.
        script.permission = ["toolCall": ["title": "Something"],
                             "options": [["optionId": "allow_once", "name": "Allow", "kind": "allow_once"]]]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        // Output reaches the windows as it arrives, which is the thing worth asserting:
        // the terminal itself is let go when the agent is, along with the runtime.
        let heard = Heard()
        await core.setBroadcaster { method, params in
            guard method == DaemonAPI.Notification.agentTerminalOutput else { return }
            heard.add(params?["chunk"]?.stringValue ?? "")
        }

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "run it"))

        let created = await eventuallySome("the terminal was created") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createTerminal)
        }
        guard case .success(let result)? = created, result["terminalId"]?.stringValue != nil else {
            Issue.record("the terminal was not created: \(String(describing: created))")
            return
        }
        // Creating the terminal and hearing from it are two separate waits. The pty
        // gathers what it reads before handing it on, so the output lands a beat after
        // the command is answered — which is the beat the old fixed sleep kept losing.
        await eventually("the command's output reached the windows") {
            heard.text.contains("probe-ran")
        }
        #expect(heard.text.contains("probe-ran"))
    }

    @Test func aCommandOutsideTheAgentsFoldersIsRefused() async throws {
        let (locations, work) = try temporary()
        let elsewhere = try temporary().1
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createTerminal,
                                  ["command": "echo", "args": ["nope"], "cwd": .string(elsewhere.path)])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        _ = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "run it"))

        let created = await eventuallySome("an answer to the terminal request") {
            await launcher.lastAgent?.answer(to: ACP.ClientMethod.createTerminal)
        }
        guard case .failure? = created else {
            Issue.record("expected a refusal")
            return
        }
    }

    @Test func everyTerminalDiesWithTheAgentThatAskedForIt() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createTerminal,
                                  ["command": "sleep", "args": ["30"], "cwd": .string(work.path)])]
        // The turn stays open on a question, so the agent is still running while we look.
        script.permission = ["toolCall": ["title": "Something"],
                             "options": [["optionId": "allow_once", "name": "Allow", "kind": "allow_once"]]]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "run it"))
        await eventually("the terminal started") { await core.terminals(for: id).runningCount == 1 }
        #expect(await core.terminals(for: id).runningCount == 1)

        try await core.stop(id)
        await eventually("the terminal went with it") { await core.terminals(for: id).runningCount == 0 }
        #expect(await core.terminals(for: id).runningCount == 0,
                "a command outliving its agent is an orphan process")
    }

    @Test func theDaemonTakesItsTerminalsWithIt() async throws {
        let (locations, work) = try temporary()
        var script = FakeACPAgent.Script()
        script.clientRequests = [(ACP.ClientMethod.createTerminal,
                                  ["command": "sleep", "args": ["30"], "cwd": .string(work.path)])]
        let launcher = FakeLauncher(script: script, capabilities: serving)
        let core = try core(launcher, locations: locations)

        let id = try await core.start(.init(runtimeID: "grok", cwd: work, prompt: "run it"))
        // The terminal has to be up before the shutdown means anything: shutting down
        // before it starts would pass for the wrong reason.
        await eventually("the terminal started") { await core.terminals(for: id).runningCount == 1 }

        await core.shutDown()
        #expect(await core.terminals(for: id).runningCount == 0)
    }
}
