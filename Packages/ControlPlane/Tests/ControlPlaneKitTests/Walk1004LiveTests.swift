import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// The walk for #1004, against the devbox: as #691's walk (`Walk691LiveTests`), the box is
/// added over ssh and linked to a docker provider for its container, with a 1-minute stop when
/// idle. Its host is given a workflow due at the next half hour at least 12 minutes off
/// (`specs/1004-workspace-wake-up-calls/walks/box-workflow.sh`). It goes idle and is stopped;
/// the control plane starts it before the due time, the host fires the workflow on its own
/// clock, and it is stopped again. Only when `AGENTS_WALK1004_URL` is set.
///
///   AGENTS_WALK1004_URL=https://<LAN address>:<port> AGENTS_WALK1004_HOME=$ROOT/control \
///   AGENTS_WALK1004_ROOT=$ROOT AGENTS_WALK1004_TOOL=<agents-control> swift test --filter Walk1004
@Suite("Walk #1004: a wake-up call", .serialized, .timeLimit(.minutes(60)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK1004_URL"] != nil))
struct Walk1004LiveTests {
    let environment = ProcessInfo.processInfo.environment
    var url: URL { URL(string: environment["AGENTS_WALK1004_URL"]!)! }
    var home: String { environment["AGENTS_WALK1004_HOME"]! }
    var tool: String { environment["AGENTS_WALK1004_TOOL"]! }
    let name = "w1004-devbox"

    func note(_ line: String) { print("WALK1004 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

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
                                                                id: client, publicKey: key.publicKey, name: "walk1004 window", kind: .mac)))))
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

    var root: String { environment["AGENTS_WALK1004_ROOT"]! }
    var script: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(
            "../../../../specs/1004-workspace-wake-up-calls/walks/box-workflow.sh").standardized.path
    }

    @Test func walk() async throws {
        let (link, control) = try await window()
        defer { link.disconnect() }
        _ = try docker(["start", "agents-devbox"])
        while let host = await row(control) {
            _ = try await control.call(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host.id))
        }

        var install: [String: JSONValue] = ["destination": "ssh://agents@127.0.0.1:2222", "name": .string(name)]
        var answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(install))
        if let fingerprint = answer["needsTrust"]?.stringValue {
            install["trust"] = .string(fingerprint)
            answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(install))
        }
        guard await within(120, "\(name) online", { await row(control)?.state == "online" }) else { return }

        // The workflow, due at the next half hour at least 12 minutes off, in the box's UTC.
        var due = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 1800).rounded(.up) * 1800)
        while due.timeIntervalSinceNow < 12 * 60 { due += 1800 }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let parts = utc.dateComponents([.hour, .minute], from: due)
        let at = String(format: "%02d:%02d", parts.hour!, parts.minute!)
        note("workflow due \(due) (\(at) UTC on the box)")
        note(try run("/bin/bash", [script, root, at]).1.suffix(600).description)

        let added = try await control.call(DaemonAPI.Method.providersAdd, try JSONValue.encoding(DaemonAPI.ProviderAdd(
            name: "Walk 1004 Docker", kind: .commands,
            commands: ["preset": "docker", "containers": ["agents-devbox"], "ssh": "agents@127.0.0.1 -p 2222"])))
            .decode(DaemonAPI.ProviderSummary.self)
        let host = try #require(await row(control))
        _ = try await control.call(DaemonAPI.Method.hostsLink,
                                   DaemonAPI.HostLink(host: host.id, provider: added.id, workspace: "agents-devbox"))
        _ = try await control.call(DaemonAPI.Method.hostsSetWorkspaceOptions,
                                   DaemonAPI.HostWorkspaceOptions(host: host.id, stopWhenIdleMinutes: 1))

        // FR-002: the host says its next scheduled workflow.
        guard await within(60, "host said its schedule", { await row(control)?.workspace?.nextWorkflowAt == due }) else {
            note("row: \(String(describing: await row(control)?.workspace))")
            return
        }
        // Idle a minute: stopped, with its wake-up call on the row (FR-007).
        guard await within(240, "stopped as idle", { await row(control)?.state == "stopped" }) else { return }
        let stopped = try #require(await row(control)?.workspace)
        let wake = try #require(stopped.wakeAt)
        note("stopped row: \(stopped.stoppedBy ?? "-"); wakeAt \(wake); strip: \(OfflineWordsCopy.line(stopped))")
        #expect(wake == due.addingTimeInterval(-300))

        // FR-004: started before the due time, once.
        guard await within(due.timeIntervalSinceNow + 60, "started by its wake-up call",
                           { await row(control)?.state == "starting" }) else { return }
        note("starting \(String(format: "%.0f", due.timeIntervalSinceNow)) s before the due time")
        guard await within(400, "online for the workflow", { await row(control)?.state == "online" }) else { return }
        note("online \(String(format: "%.0f", due.timeIntervalSinceNow)) s before the due time")
        #expect(Date() < due)

        // FR-001: the host fires it on its own clock.
        _ = await within(due.timeIntervalSinceNow + 120, "the workflow ran") {
            let listed = (try? run("/bin/bash", [script, root, "check"]).1) ?? ""
            return listed.contains("lastFiredAt")
        }
        note(try run("/bin/bash", [script, root, "check"]).1.suffix(800).description)

        // Idle again after the run: stopped again, its next call a day off.
        _ = await within(600, "stopped again after the run", { await row(control)?.state == "stopped" })
        note("after: \(String(describing: await row(control)?.workspace.map { ($0.stoppedBy, $0.wakeAt, $0.nextWorkflow) }))")

        if environment["AGENTS_WALK1004_KEEP"] == "1" { return }
        _ = try docker(["start", "agents-devbox"])
        _ = try await control.call(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host.id))
        _ = try await control.call(DaemonAPI.Method.providersRemove, DaemonAPI.ProviderRequest(id: added.id))
    }
}

/// The strip's words, as `OfflineWords.workspaceLine` says them (Shared/UI isn't in this package).
enum OfflineWordsCopy {
    static func line(_ workspace: DaemonAPI.HostWorkspace) -> String {
        guard let at = workspace.wakeAt, let workflow = workspace.nextWorkflow else { return "no wake-up call" }
        let parts = Calendar.current.dateComponents([.hour, .minute], from: at)
        return "Starts at \(String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)) for \(workflow)"
    }
}
