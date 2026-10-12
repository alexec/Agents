import AgentsKit
import AgentsKitCore
import Foundation
import Testing
@testable import ControlPlaneKit

/// A real stdio provider that breaks the contract on purpose (#857): each way is a clear
/// sentence for the person, and the connection is usable again after it.
@Suite("A provider that breaks the contract (#857)", .timeLimit(.minutes(1)))
struct MisbehavingProviderTests {
    /// Newline-delimited JSON-RPC. `FAKE_MODE` says how it misbehaves; anything else is a
    /// well-behaved provider of one stopped workspace, `devbox`.
    static let script = #"""
    import json, os, sys, threading, time
    mode = os.environ.get("FAKE_MODE", "")
    out = threading.Lock()

    def send(message):
        with out:
            sys.stdout.write(json.dumps(message) + "\n")
            sys.stdout.flush()

    def answer(id, content=None, text=None, error=False):
        result = {"content": [{"type": "text", "text": text if text is not None else json.dumps(content)}]}
        if content is not None and text is None:
            result["structuredContent"] = content
        if error:
            result["isError"] = True
        send({"jsonrpc": "2.0", "id": id, "result": result})

    def item(**fields):
        return dict({"id": "devbox", "name": "devbox", "state": "stopped"}, **fields)

    def listing():
        if mode == "no-contract":
            return {"workspaces": [item()]}
        if mode == "contract-2":
            return {"contract": 2, "workspaces": [item()]}
        if mode == "odd-items":
            return {"contract": 1, "workspaces": [
                item(state="Hibernating"), {"name": "no-id", "state": "running"}, item(id="", name="empty-id"),
                item(id="devbox", name="twin", state="running"), "not an object", item(id=7, name="numbered")]}
        return {"contract": 1, "workspaces": [item()]}

    def call(id, tool):
        if tool == "workspaces_list":
            if mode == "not-json":
                answer(id, text="devbox is stopped")
            else:
                answer(id, listing())
        elif mode == "crash" and tool == "workspace_start":
            os._exit(3)
        elif mode == "hang" and tool == "workspace_start":
            time.sleep(30)
        elif mode == "refuse":
            answer(id, text="Quota exceeded. " + "x" * 3000, error=True)
        elif mode == "silent-refusal":
            answer(id, text="", error=True)
        elif mode == "bare-start":
            answer(id, {})
        else:
            answer(id, {"workspace": item(state="running" if tool == "workspace_start" else "stopped")})

    # readline, not `for line in sys.stdin`, which waits for more than one line on a pipe.
    for line in iter(sys.stdin.readline, ""):
        message = json.loads(line)
        method, id = message.get("method"), message.get("id")
        if method == "initialize":
            if mode == "noise":
                sys.stdout.write("starting up...\n")
            send({"jsonrpc": "2.0", "id": id, "result": {"protocolVersion": "2025-06-18",
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}})
        elif method == "tools/list":
            names = ["workspaces_list", "workspace_start", "workspace_stop"]
            if mode == "no-stop":
                names.remove("workspace_stop")
            send({"jsonrpc": "2.0", "id": id, "result": {"tools": [{"name": n, "inputSchema": {"type": "object"}} for n in names]}})
        elif method == "tools/call":
            # Each call on its own thread, as a server whose calls overlap.
            threading.Thread(target=call, args=(id, message["params"]["name"]), daemon=True).start()
        elif id is not None:
            send({"jsonrpc": "2.0", "id": id, "result": {}})
    """#

    /// In a folder of its own: Python reads the script's folder for every import, and the
    /// temporary folder can hold enough to make that slower than a call's time.
    private static let scriptFile: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("misbehaving-provider-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("provider.py")
        try? script.write(to: file, atomically: true, encoding: .utf8)
        return file
    }()

    private func provider(_ mode: String, timing: ProviderConnection.Timing = .init(quick: .seconds(5), long: .seconds(5))) throws
        -> ProviderConnection {
        let record = ProviderRecord(id: .init(rawValue: "fake-\(mode)"), name: "Fake", kind: .stdio,
                                    command: "python3", args: ["-u", Self.scriptFile.path])
        return try ProviderConnection(record: record, secrets: ["FAKE_MODE": mode],
                                      cwd: Self.scriptFile.deletingLastPathComponent(), timing: timing, log: { _ in })
    }

    /// What `work` threw, as the person reads it.
    private func said(_ work: () async throws -> some Any) async -> String? {
        do {
            _ = try await work()
            return nil
        } catch {
            return "\(error)"
        }
    }

    @Test func aWellBehavedOneIsReadAsTheContractSays() async throws {
        let fake = try provider("")
        let checked = try await fake.check()
        #expect(checked.workspaces.map(\.state) == ["stopped"])
        #expect(try await fake.start("devbox")?.state == "running")
        await fake.end()
    }

    @Test func aMissingToolIsNamed() async throws {
        let fake = try provider("no-stop")
        #expect(await said { try await fake.check() } == "It isn’t a workspace provider: it has no workspace_stop tool.")
        await fake.end()
    }

    @Test func aListWithoutItsContractOrWithAnUnknownOneIsRefused() async throws {
        let none = try provider("no-contract")
        #expect(await said { try await none.check() } == "Its workspaces_list doesn’t say which contract it follows.")
        await none.end()
        let later = try provider("contract-2")
        #expect(await said { try await later.check() } == "It follows contract 2; this control plane reads 1.")
        await later.end()
    }

    @Test func oddItemsAreLeftOutOrReadAsUnknown() async throws {
        let fake = try provider("odd-items")
        let listed = try await fake.list()
        // An unknown state is unknown; no id, an empty id or not an object is left out. A
        // number is an id. A second item with the same id is a second row, as the provider said.
        #expect(listed.map(\.name) == ["devbox", "twin", "numbered"])
        #expect(listed.first?.state == "unknown")
        #expect(listed.last?.id == "7")
        await fake.end()
    }

    @Test func textThatIsNotJSONIsSaidSo() async throws {
        let fake = try provider("not-json")
        #expect(await said { try await fake.list() } == "The provider’s answer isn’t JSON.")
        await fake.end()
    }

    @Test func aLineThatIsNotJSONRPCIsPassedOver() async throws {
        let fake = try provider("noise")
        #expect(try await fake.check().workspaces.count == 1)
        await fake.end()
    }

    @Test func aRefusalIsInItsOwnWordsCutAt1KB() async throws {
        let fake = try provider("refuse")
        let refusal = try #require(await said { try await fake.start("devbox") })
        #expect(refusal.hasPrefix("Quota exceeded."))
        #expect(refusal.utf8.count == 1024)
        await fake.end()
        let silent = try provider("silent-refusal")
        #expect(await said { try await silent.start("devbox") } == "The provider said no, and not why.")
        await silent.end()
    }

    @Test func aStartWithoutItsWorkspaceIsNotAFailure() async throws {
        let fake = try provider("bare-start")
        #expect(try await fake.start("devbox") == nil)
        await fake.end()
    }

    @Test func aHungStartRunsOutOfTimeAndTheNextCallStillWorks() async throws {
        let fake = try provider("hang", timing: .init(quick: .seconds(5), long: .seconds(1)))
        #expect(await said { try await fake.start("devbox") } == "It didn’t answer in time.")
        #expect(try await fake.list().count == 1)
        await fake.end()
    }

    @Test func aCrashMidStartIsSaidAndTheNextCallStartsItAgain() async throws {
        let fake = try provider("crash")
        let crash = try #require(await said { try await fake.start("devbox") })
        #expect(!crash.isEmpty)
        #expect(try await fake.list().count == 1)
        await fake.end()
    }
}
