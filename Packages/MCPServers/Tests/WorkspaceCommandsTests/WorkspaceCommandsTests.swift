// The command provider (#691): its configuration, its presets' command lines, and the
// contract's tools, driven in process. Commands either run in a real /bin/sh (true, false,
// files in a scratch folder) or go to a recorder that answers as a CLI would.
import Foundation
import MCPServerKit
import Testing
@testable import WorkspaceCommands

/// Answers each command line with what `answer` says, and keeps every line it was given.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    let answer: @Sendable (String) -> (Int32, String)

    init(_ answer: @escaping @Sendable (String) -> (Int32, String)) { self.answer = answer }

    var lines: [String] { lock.withLock { _lines } }

    var run: WorkspaceCommands.Runner {
        { [self] line, _ in
            lock.withLock { _lines.append(line) }
            let (status, output) = answer(line)
            return ChildProcess.Outcome(status: status, output: Data(output.utf8), errors: Data())
        }
    }
}

let quick = WorkspaceCommands.Timing(quick: .seconds(5), long: .seconds(5), pollEvery: .milliseconds(20))

func call(_ server: MCPServer, _ tool: String, _ arguments: JSON = [:]) async throws -> JSON {
    try await server.handle(method: "tools/call", params: ["name": .string(tool), "arguments": arguments])
}

func config(_ json: JSON) throws -> CommandConfig { try CommandConfig.from(json) }

@Suite struct CommandConfigTests {
    @Test func writtenOutWorkspacesTakeTheirNameAsID() throws {
        let c = try config(["workspaces": [["name": "devstack", "start": "cws start", "stop": "cws stop"]]])
        #expect(c.workspaces.map(\.id) == ["devstack"])
        #expect(c.workspaces[0].commands.status == nil)
    }

    @Test func refusesWhatCannotRun() {
        #expect(throws: ConfigError("give workspaces, a list command, or a preset")) { try config([:]) }
        #expect(throws: ConfigError("devstack: no stop command")) {
            try config(["workspaces": [["name": "devstack", "start": "x"]]])
        }
        #expect(throws: ConfigError("columns must name an id column")) {
            try config(["list": "x", "columns": ["name"], "start": "a", "stop": "b"])
        }
        #expect(throws: ConfigError("states.on must be one of running, starting, stopping, stopped, unknown")) {
            try config(["workspaces": [["name": "a", "start": "x", "stop": "y"]], "states": ["on": "up"]])
        }
        #expect(throws: ConfigError("no preset vagrant; there are docker, doctl, codespaces, coder, gcloud-workstations")) {
            try config(["preset": "vagrant"])
        }
        #expect(throws: ConfigError("WORKSPACE_COMMANDS_CONFIG isn't JSON")) { try CommandConfig.parse("") }
    }

    @Test func statesAreMatchedWithoutCaseOrSpace() throws {
        let c = try config(["workspaces": [["name": "a", "start": "x", "stop": "y"]], "states": ["Exited": "stopped"]])
        #expect(c.state(for: " exited\n") == .stopped)
        #expect(c.state(for: "RUNNING") == .running)
        #expect(c.state(for: "on fire") == .unknown)
    }

    @Test func templateValuesAreOneShellWord() {
        let line = Template.fill("cws start ${name}", ["name": "x'; rm -rf / #"], quoted: true)
        #expect(line == #"cws start 'x'\''; rm -rf / #'"#)
        #expect(Template.fill("${user}@${ip}", ["user": "root", "ip": "10.0.0.2"], quoted: false) == "root@10.0.0.2")
        // A name with no value is left for the shell: a secret in the environment.
        #expect(Template.fill("curl -H \"Authorization: ${TOKEN}\" ${id}", ["id": "7"], quoted: true)
                == "curl -H \"Authorization: ${TOKEN}\" '7'")
    }

    @Test func pathsReadNestedValues() throws {
        let json = try JSON.parse(#"{"networks":{"v4":[{"ip_address":"1.2.3.4"}]},"id":12}"#)
        #expect(JSONPath.text("networks.v4[0].ip_address", in: json) == "1.2.3.4")
        #expect(JSONPath.text("id", in: json) == "12")
        #expect(JSONPath.value("networks.v6[0]", in: json) == nil)
    }
}

@Suite struct PresetTests {
    @Test func noPresetAsksForSudo() throws {
        let configs: [JSON] = [
            ["preset": "docker", "containers": ["agents-devbox"]],
            ["preset": "doctl", "tag": "agents"],
            ["preset": "codespaces"],
            ["preset": "coder"],
            ["preset": "gcloud-workstations", "cluster": "c", "config": "f", "region": "r"],
        ]
        for json in configs {
            let c = try config(json)
            let commands = c.workspaces.map(\.commands) + [c.listing?.commands].compactMap { $0 }
            let lines = commands.flatMap { [$0.start, $0.stop, $0.status ?? ""] } + [c.listing?.command ?? ""]
            #expect(!lines.contains { $0.contains("sudo") }, "\(json)")
        }
        #expect(Presets.names.count == configs.count)
    }

    @Test func dockerRunsTheContainersCommands() async throws {
        let recorder = Recorder { line in
            line.hasPrefix("docker inspect") ? (0, "exited\n") : (0, "")
        }
        let server = WorkspaceCommands.server(
            try config(["preset": "docker", "containers": ["agents-devbox"], "ssh": "alex@127.0.0.1 -p 2222"]),
            timing: quick, run: recorder.run)
        let list = try await call(server, "workspaces_list")
        #expect(list["structuredContent"] == [
            "contract": 1,
            "workspaces": [["id": "agents-devbox", "name": "agents-devbox", "state": "stopped",
                            "ssh": "alex@127.0.0.1 -p 2222", "tunnel": false]],
        ])
        #expect(recorder.lines == ["docker inspect -f '{{.State.Status}}' 'agents-devbox'"])
    }

    @Test func doctlListsByTagAndReachesTheDropletByItsAddress() async throws {
        let recorder = Recorder { line in
            if line.hasPrefix("doctl compute droplet list") {
                return (0, "4101  devbox  off  203.0.113.7\n4102  build  active  203.0.113.8\n")
            }
            return (0, "")
        }
        let server = WorkspaceCommands.server(try config(["preset": "doctl", "tag": "agents"]), timing: quick, run: recorder.run)
        let list = try await call(server, "workspaces_list")
        #expect(list["structuredContent"]?["workspaces"] == [
            ["id": "4101", "name": "devbox", "state": "stopped", "ssh": "root@203.0.113.7", "tunnel": false],
            ["id": "4102", "name": "build", "state": "running", "ssh": "root@203.0.113.8", "tunnel": false],
        ])
        #expect(recorder.lines.first == "doctl compute droplet list --tag-name 'agents' --format ID,Name,Status,PublicIPv4 --no-header")
    }

    @Test func presetsCommandLines() throws {
        let doctl = try #require(try config(["preset": "doctl", "tag": "agents"]).listing)
        #expect(doctl.commands.start == "doctl compute droplet-action power-on ${id} --wait")
        #expect(doctl.commands.stop == "doctl compute droplet-action power-off ${id} --wait")

        let codespaces = try #require(try config(["preset": "codespaces", "repo": "alexec/Agents"]).listing)
        #expect(codespaces.command == "gh codespace list --repo 'alexec/Agents' --json name,displayName,state")
        #expect(codespaces.commands.start == "gh codespace ssh -c ${id} -- true")
        #expect(codespaces.commands.stop == "gh codespace stop -c ${id}")
        #expect(codespaces.commands.tunnel)

        let coder = try #require(try config(["preset": "coder"]).listing)
        #expect(coder.command == "coder list -o json")
        #expect(coder.commands.start == "coder start -y ${id}")
        #expect(coder.commands.ssh == "coder.${name}")

        let gcloud = try #require(try config(["preset": "gcloud-workstations", "cluster": "c", "config": "f", "region": "r"]).listing)
        #expect(gcloud.command == "gcloud workstations list --cluster='c' --config='f' --region='r' --format='value(name.basename(),state)'")
        #expect(gcloud.commands.start == "gcloud workstations start ${id} --cluster='c' --config='f' --region='r'")

        #expect(throws: ConfigError("the doctl preset needs a tag")) { try config(["preset": "doctl"]) }
        #expect(throws: ConfigError("the gcloud-workstations preset needs region")) {
            try config(["preset": "gcloud-workstations", "cluster": "c", "config": "f"])
        }
    }

    @Test func coderStatesComeFromItsJSON() async throws {
        let recorder = Recorder { _ in
            (0, #"[{"name":"dev","latest_build":{"status":"stopped"}},{"name":"ci","latest_build":{"status":"running"}}]"#)
        }
        let server = WorkspaceCommands.server(try config(["preset": "coder"]), timing: quick, run: recorder.run)
        let list = try await call(server, "workspaces_list")
        #expect(list["structuredContent"]?["workspaces"]?.array?.map { $0["state"]?.string } == ["stopped", "running"])
        #expect(list["structuredContent"]?["workspaces"]?[0]?["ssh"] == "coder.dev")
    }
}

@Suite struct WorkspaceCommandsServerTests {
    let scratch: URL

    init() throws {
        scratch = FileManager.default.temporaryDirectory.appending(path: "workspace-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    /// A workspace whose state is a file: start makes it, stop takes it away.
    func fileBacked(start: String? = nil) throws -> MCPServer {
        let marker = Template.shellQuoted(scratch.appending(path: "up").path)
        return WorkspaceCommands.server(try config([
            "workspaces": [[
                "name": "devbox",
                "start": .string(start ?? "touch \(marker)"),
                "stop": .string("rm -f \(marker)"),
                "status": .string("test -e \(marker) && echo running || echo stopped"),
            ]],
        ]), timing: quick)
    }

    @Test func listsToolsOfTheContract() async throws {
        let server = try fileBacked()
        let tools = try await server.handle(method: "tools/list", params: nil)["tools"]?.array?.compactMap { $0["name"]?.string }
        #expect(tools == ["workspaces_list", "workspace_start", "workspace_stop"])
    }

    @Test func startsAndStopsThroughTheShell() async throws {
        let server = try fileBacked()
        #expect(try await call(server, "workspaces_list")["structuredContent"]?["workspaces"]?[0]?["state"] == "stopped")
        let started = try await call(server, "workspace_start", ["id": "devbox"])
        #expect(started["isError"] == nil)
        #expect(started["structuredContent"]?["workspace"]?["state"] == "running")
        let stopped = try await call(server, "workspace_stop", ["id": "devbox"])
        #expect(stopped["structuredContent"]?["workspace"]?["state"] == "stopped")
    }

    @Test func startWaitsForTheStatusToSayRunning() async throws {
        // The start returns at once; the workspace is up a moment later, as a cloud one is.
        let marker = Template.shellQuoted(scratch.appending(path: "up").path)
        let server = try fileBacked(start: "(sleep 0.3; touch \(marker)) >/dev/null 2>&1 &")
        let started = try await call(server, "workspace_start", ["id": "devbox"])
        #expect(started["structuredContent"]?["workspace"]?["state"] == "running")
    }

    @Test func aFailedStartSaysWhyInTheCommandsWords() async throws {
        let server = try fileBacked(start: "echo 'Error: droplet is locked' >&2; exit 1")
        let result = try await call(server, "workspace_start", ["id": "devbox"])
        #expect(result["isError"] == true)
        #expect(result["content"]?[0]?["text"] == "Error: droplet is locked")
    }

    @Test func aMissingCLIIsNamed() async throws {
        let server = try fileBacked(start: "no-such-cli-691 start devbox")
        let result = try await call(server, "workspace_start", ["id": "devbox"])
        #expect(result["content"]?[0]?["text"] == "no-such-cli-691 isn't installed where the control plane runs.")
    }

    @Test func aStartThatNeverComesUpTimesOut() async throws {
        let server = WorkspaceCommands.server(try config([
            "workspaces": [["name": "devbox", "start": "true", "stop": "true", "status": "echo starting"]],
        ]), timing: .init(quick: .seconds(5), long: .milliseconds(300), pollEvery: .milliseconds(50)))
        let result = try await call(server, "workspace_start", ["id": "devbox"])
        #expect(result["content"]?[0]?["text"] == "devbox was still starting after 0 seconds.")
    }

    @Test func withoutAStatusTheLastActionIsTheState() async throws {
        let server = WorkspaceCommands.server(try config([
            "workspaces": [["name": "devstack", "start": "true", "stop": "true"]],
        ]), timing: quick)
        #expect(try await call(server, "workspaces_list")["structuredContent"]?["workspaces"]?[0]?["state"] == "unknown")
        _ = try await call(server, "workspace_start", ["id": "devstack"])
        #expect(try await call(server, "workspaces_list")["structuredContent"]?["workspaces"]?[0]?["state"] == "running")
    }

    @Test func anUnknownWorkspaceIsRefused() async throws {
        let result = try await call(try fileBacked(), "workspace_start", ["id": "nope"])
        #expect(result["content"]?[0]?["text"] == "There is no workspace nope.")
    }

    @Test func aSecretReachesTheCommandFromTheEnvironment() async throws {
        // The control plane passes secrets as the server's environment; commands inherit it.
        setenv("WORKSPACE_COMMANDS_TEST_TOKEN", "hunter2", 1)
        defer { unsetenv("WORKSPACE_COMMANDS_TEST_TOKEN") }
        let server = WorkspaceCommands.server(try config([
            "workspaces": [["name": "devbox", "start": "test \"$WORKSPACE_COMMANDS_TEST_TOKEN\" = hunter2", "stop": "true"]],
        ]), timing: quick)
        let result = try await call(server, "workspace_start", ["id": "devbox"])
        #expect(result["isError"] == nil)
        #expect(!result.text.contains("hunter2"))
    }

    @Test func aListingIsCutAt200() async throws {
        let rows = (1...250).map { "w\($0) stopped" }.joined(separator: "\n")
        let recorder = Recorder { _ in (0, rows) }
        let server = WorkspaceCommands.server(try config([
            "list": "cloud ls", "columns": ["id", "state"], "start": "cloud up ${id}", "stop": "cloud down ${id}",
        ]), timing: quick, run: recorder.run)
        let list = try await call(server, "workspaces_list")
        #expect(list["structuredContent"]?["workspaces"]?.array?.count == 200)
    }
}
