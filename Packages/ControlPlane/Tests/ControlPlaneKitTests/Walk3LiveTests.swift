import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// Quickstart Walk 3 against the devbox (058, US4, T075): a control plane on this Mac at an
/// address the devbox can reach, and the devbox joining both ways. Only when
/// `AGENTS_WALK3_URL` is set; it runs commands in the `agents-devbox` container.
///
///   AGENTS_WALK3_URL=https://<this Mac's address>:18821 AGENTS_WALK3_HOME=/tmp/w3/control \
///   AGENTS_WALK3_KEY=/tmp/w3/key swift test --filter Walk3
@Suite("Walk 3: a server joins", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK3_URL"] != nil))
struct Walk3LiveTests {
    let environment = ProcessInfo.processInfo.environment
    var url: URL { URL(string: environment["AGENTS_WALK3_URL"]!)! }
    var home: String { environment["AGENTS_WALK3_HOME"] ?? "/tmp/w3/control" }
    var keyFile: String { environment["AGENTS_WALK3_KEY"] ?? "/tmp/w3/key" }
    var tool: String {
        environment["AGENTS_WALK3_TOOL"] ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/debug/agents-control").path
    }

    func note(_ line: String) { print("WALK3 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

    @discardableResult
    func run(_ executable: String, _ arguments: [String], environment extra: [String: String] = [:]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        for (k, v) in extra { env[k] = v }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func devbox(_ command: String, root: Bool = false) throws -> String {
        try run("/usr/bin/env", ["docker", "exec"] + (root ? [] : ["-u", "agents"]) + ["agents-devbox", "sh", "-c", command]).1
    }

    func docker(_ arguments: [String]) throws -> String { try run("/usr/bin/env", ["docker"] + arguments).1 }

    /// An operator window, paired with a code from the control plane's own command.
    func operatorLink() async throws -> ControlLink {
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
                                                                id: client, publicKey: key.publicKey, name: "walk3 window", kind: .mac)))))
        _ = try await reader.next(within: 10)
        reader.close()
        let shared = try ControlAuth.clientKey(privateKey: key.privateKey, peer: code.controlKey, client: client)
        let credentials = ControlAuth.Credentials(identity: .client(client), key: shared, kind: "mac", controlKey: code.controlKey)
        let pin = code.pin
        let url = self.url
        return ControlLink { try await ControlJoin.dial(url, pin: pin, as: credentials) }
    }

    func hosts(_ control: DaemonClient) async -> [DaemonAPI.ControlHost] {
        (try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlHost].self)) ?? []
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

    @Test func walk3() async throws {
        let link = try await operatorLink()
        defer { link.disconnect() }
        let control = DaemonClient(link: link.controlLink)
        try await control.connect(startIfNeeded: false)
        _ = try? devbox(#"p=$(cat ~/.agents-server/root/daemon.lock 2>/dev/null); [ -n "$p" ] && kill $p; rm -rf ~/.agents-server"#)
        let before = Set(await hosts(control).map(\.id))

        // 1. The command, run on the devbox as its user.
        let shown = try await control.call(DaemonAPI.Method.hostsStartEnroll, returning: DaemonAPI.ControlCodeShown.self)
        let command = try #require(shown.command)
        note("command: \(command.prefix(90))…")
        let out = try devbox(command + " 2>&1")
        note("the devbox said: \(out.split(separator: "\n").suffix(3).joined(separator: " / "))")
        var first: DaemonAPI.ControlHost?
        _ = await within(40, "the devbox joins by command") {
            first = await hosts(control).first { !before.contains($0.id) && $0.state == "online" }
            return first != nil
        }
        let byCommand = try #require(first)
        note("joined as \(byCommand.id) (\(byCommand.name), \(byCommand.platform))")

        // 2. Again, over ssh with a scratch key: the control plane installs once and lets go.
        let publicKey = try String(contentsOfFile: keyFile + ".pub", encoding: .utf8)
        _ = try devbox("mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '\(publicKey.trimmingCharacters(in: .newlines))' ~/.ssh/authorized_keys 2>/dev/null || echo '\(publicKey.trimmingCharacters(in: .newlines))' >> ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys")
        let key = try String(contentsOfFile: keyFile, encoding: .utf8)
        let ask: JSONValue = ["destination": "agents@127.0.0.1:2222", "name": "devbox by ssh", "key": .string(key)]
        let trustAsked = try await control.call(DaemonAPI.Method.hostsInstall, ask)
        let fingerprint = try #require(trustAsked["needsTrust"]?.stringValue)
        note("host key shown: \(fingerprint)")
        var trusted = ask.objectValue ?? [:]
        trusted["trust"] = .string(fingerprint)
        let installed = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(trusted))
        note("installed: \(installed)")
        var second: DaemonAPI.ControlHost?
        _ = await within(40, "the devbox joins after the ssh install") {
            second = await hosts(control).first { $0.name == "devbox by ssh" && $0.state == "online" }
            return second != nil
        }
        let (_, sshLeft) = try run("/bin/sh", ["-c", "pgrep -fl 'ssh.*2222' || true"])
        note("ssh processes left on this Mac: \(sshLeft.isEmpty ? "none" : sshLeft)")
        #expect(sshLeft.isEmpty)
        let (_, keyLeft) = try run("/bin/sh", ["-c", "grep -rl 'OPENSSH PRIVATE KEY' '\(home)' \"${TMPDIR:-/tmp}\"/agents-install-* 2>/dev/null || true"])
        note("the key in files under the control plane or its temporary folders: \(keyLeft.isEmpty ? "none" : keyLeft)")
        #expect(keyLeft.isEmpty)
        let host = try #require(second)

        // 3. The devbox's network goes for 60 s, then comes back: the host reconnects.
        let daemonBefore = try devbox("cat ~/.agents-server/root/daemon.lock").trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try docker(["network", "disconnect", "bridge", "agents-devbox"])
        let off = Date()
        note("network off")
        // The keep-alive notices a dead connection only after two missed pongs (about 60 s),
        // so within a 60 s drop the host may never be shown offline: noted, not required.
        var seenOffline = false
        while Date().timeIntervalSince(off) < 60 {
            if await hosts(control).first(where: { $0.id == host.id })?.state != "online" {
                if !seenOffline { note("shown offline after \(String(format: "%.0f", Date().timeIntervalSince(off))) s") }
                seenOffline = true
            }
            try await Task.sleep(for: .seconds(2))
        }
        if !seenOffline { note("not shown offline during the 60 s drop: the connection outlived it") }
        try await Task.sleep(for: .seconds(max(0, 60 - Date().timeIntervalSince(off))))
        _ = try docker(["network", "connect", "bridge", "agents-devbox"])
        note("network back")
        _ = await within(60, "the host is back online") { await hosts(control).first { $0.id == host.id }?.state == "online" }
        let daemonAfter = try devbox("cat ~/.agents-server/root/daemon.lock").trimmingCharacters(in: .whitespacesAndNewlines)
        note("the host's daemon: \(daemonBefore) before, \(daemonAfter) after")
        #expect(daemonBefore == daemonAfter)

        // 4. Remove it: gone from the list, still running on the devbox.
        _ = try await control.call(DaemonAPI.Method.hostsRemove, JSONValue.object(["host": .string(host.id.rawValue)]))
        _ = await within(10, "the host is gone from the list") { await !hosts(control).contains { $0.id == host.id } }
        let running = try devbox("kill -0 $(cat ~/.agents-server/root/daemon.lock) && echo running || echo stopped")
        note("on the devbox after removal: \(running.trimmingCharacters(in: .whitespacesAndNewlines))")
        #expect(running.contains("running"))
        // The first, joined by command, is removed too, so the walk leaves no host behind.
        _ = try? await control.call(DaemonAPI.Method.hostsRemove, JSONValue.object(["host": .string(byCommand.id.rawValue)]))
    }
}

