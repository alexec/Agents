import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// The walk for #691 US1 and US2, against the devbox: a scratch control plane on this Mac
/// (`run-app` `launch.sh --lan --control-env AGENTS_WORKSPACE_COMMANDS=<workspace-commands>`),
/// driven as the Providers page and the strip drive it. The box is added over ssh, a docker
/// provider is added for its container and linked, the container is stopped, and Start brings
/// the host back online: the provider starts the container, and since the box has no systemd,
/// the control plane starts agentsd over ssh after two minutes. Only when
/// `AGENTS_WALK691_URL` is set.
///
///   AGENTS_WALK691_URL=https://<LAN address>:<port> AGENTS_WALK691_HOME=/tmp/run-x/control \
///   AGENTS_WALK691_TOOL=<agents-control> swift test --filter Walk691
///
/// With `AGENTS_WALK691_KEEP=1` it stops once the box is linked and stopped, and leaves them,
/// for a look at the screens.
@Suite("Walk #691: start a stopped workspace", .serialized, .timeLimit(.minutes(15)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK691_URL"] != nil))
struct Walk691LiveTests {
    let environment = ProcessInfo.processInfo.environment
    var url: URL { URL(string: environment["AGENTS_WALK691_URL"]!)! }
    var home: String { environment["AGENTS_WALK691_HOME"]! }
    var tool: String { environment["AGENTS_WALK691_TOOL"]! }
    let name = "w691-devbox"

    func note(_ line: String) { print("WALK691 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func docker(_ arguments: [String]) throws -> String { try run("/usr/bin/env", ["docker"] + arguments).1 }

    /// A window, paired with a code from the control plane's own command.
    func window() async throws -> (ControlLink, DaemonClient) {
        let (_, out) = try run(tool, ["code", "--client", "--home", home])
        let text = try #require(out.split(separator: "\n").last { $0.hasPrefix("agents-control:2:") }).description
        let code = try #require(ControlCode(text: text))
        let id = try #require(ControlAuth.codeID(secret: code.secret))
        let key = ControlAgreement.generate()
        let client = UUID()
        let reader = try await ControlJoin.dial(url, pin: code.pin, as: .init(identity: .pairing(id), key: ControlAuth.codeKey(secret: code.secret),
                                                                            kind: "mac", controlKey: code.controlKey))
        try reader.write(line: JSONRPCCodec.encode(.request(id: .number(1), method: DaemonAPI.Method.clientsAnnounce,
                                                            params: try JSONValue.encoding(DaemonAPI.ClientAnnounce(
                                                                id: client, publicKey: key.publicKey, name: "walk691 window", kind: .mac)))))
        _ = try await reader.next(within: 10)
        reader.close()
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: code.controlKey, client: client)
        let credentials = ControlAuth.Credentials(identity: .client(client), key: shared, kind: "mac", controlKey: code.controlKey)
        let pin = code.pin, url = self.url
        let link = ControlLink { try await ControlJoin.dial(url, pin: pin, as: credentials) }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        return (link, control)
    }

    func row(_ control: DaemonClient) async -> DaemonAPI.ControlHost? {
        let hosts = (try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)) ?? []
        return hosts.last { $0.name == name }
    }

    func within(_ seconds: Double, _ what: String, _ condition: () async -> Bool) async -> Bool {
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            if await condition() { note("\(what): \(String(format: "%.1f", Date().timeIntervalSince(start))) s"); return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        Issue.record("\(what): not within \(seconds) s")
        return false
    }

    @Test func walk() async throws {
        let (link, control) = try await window()
        defer { link.disconnect() }
        // Whatever an earlier walk left: the box running, no host or provider of ours.
        _ = try docker(["start", "agents-devbox"])
        while let host = await row(control) {
            _ = try await control.call(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host.id))
        }

        // US2: the box over ssh, as Add a Server does.
        var install: [String: JSONValue] = ["destination": "ssh://agents@127.0.0.1:2222", "name": .string(name)]
        var answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(install))
        if let fingerprint = answer["needsTrust"]?.stringValue {
            install["trust"] = .string(fingerprint)
            answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(install))
        }
        note("installed: \(answer)")
        guard await within(120, "\(name) online", { await row(control)?.state == "online" }) else { return }

        // A docker provider for its container: checked and listed before it is kept.
        let added = try await control.call(DaemonAPI.Method.providersAdd, try JSONValue.encoding(DaemonAPI.ProviderAdd(
            name: "Walk 691 Docker", kind: .commands,
            commands: ["preset": "docker", "containers": ["agents-devbox"], "ssh": "agents@127.0.0.1 -p 2222"])))
            .decode(DaemonAPI.ProviderSummary.self)
        note("provider: \(added.id), \(added.workspaces.map { "\($0.name) \($0.state)" })")
        #expect(added.workspaces.first?.state == "running")

        // Link to Workspace….
        let host = try #require(await row(control))
        _ = try await control.call(DaemonAPI.Method.hostsLink,
                                   DaemonAPI.HostLink(host: host.id, provider: added.id, workspace: "agents-devbox"))
        #expect(await row(control)?.workspace?.workspaceName == "agents-devbox")

        // Stopped outside Agents: offline, then stopped once the provider lists again.
        note(try docker(["stop", "-t", "2", "agents-devbox"]))
        _ = try await control.call(DaemonAPI.Method.providersRefresh, DaemonAPI.ProviderRequest(id: added.id))
        guard await within(120, "shown stopped", { await row(control)?.state == "stopped" }) else { return }
        let stopped = try #require(await row(control))
        note("stopped row: \(stopped.state), canStart \(stopped.workspace?.canStart == true)")
        #expect(stopped.workspace?.canStart == true)

        // `AGENTS_WALK691_KEEP=1`: stop here, the box linked and stopped, for screenshots.
        if environment["AGENTS_WALK691_KEEP"] == "1" { return }

        // US1: Start, as the strip's button does, twice: one start.
        let pressed = try await control.call(DaemonAPI.Method.hostsStart, DaemonAPI.HostRequest(host: host.id),
                                             returning: DaemonAPI.ControlHost.self)
        #expect(pressed.state == "starting")
        _ = try await control.call(DaemonAPI.Method.hostsStart, DaemonAPI.HostRequest(host: host.id))
        var phases: [String] = []
        let online = await within(300, "online again after Start") {
            let now = await row(control)
            if let phase = now?.workspace?.phase, phases.last != phase { phases.append(phase); note("phase \(phase)") }
            if let problem = now?.workspace?.problem { note("problem: \(problem)") }
            // Online, and the start done: Stop is offered, as a client would show it.
            return now?.state == "online" && now?.workspace?.canStop == true
        }
        note("phases: \(phases)")
        #expect(online)
        #expect(phases.contains("connecting"))
        #expect(try docker(["inspect", "-f", "{{.State.Status}}", "agents-devbox"]).contains("running"))

        // Stop, from the Hosts row.
        _ = try await control.call(DaemonAPI.Method.hostsStop, DaemonAPI.HostStop(host: host.id))
        _ = await within(120, "stopped by Stop") { await row(control)?.state == "stopped" }

        // Leave the box as it was found: running, our host and provider gone.
        _ = try docker(["start", "agents-devbox"])
        _ = try await control.call(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host.id))
        _ = try await control.call(DaemonAPI.Method.providersRemove, DaemonAPI.ProviderRequest(id: added.id))
    }
}
