import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// The walk for one ssh path (#610), against the devbox: a scratch control plane on this
/// Mac (`run-app` `launch.sh --lan --control-env AGENTS_SSH_CONFIG=<config>`), driven as Add
/// a Server ▸ Over ssh drives it. The config has `box` (known), `box-new` (its known_hosts
/// empty), `jump` and `box-behind` (`ProxyJump jump`, with forwards of its own). Only when
/// `AGENTS_WALK610_URL` is set.
///
///   AGENTS_WALK610_URL=https://<LAN address>:<port> AGENTS_WALK610_HOME=/tmp/run-x/control \
///   AGENTS_WALK610_TOOL=<agents-control> AGENTS_WALK610_CONTROL_PID=<its pid> swift test --filter Walk610
@Suite("Walk #610: one ssh path", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK610_URL"] != nil))
struct Walk610LiveTests {
    let environment = ProcessInfo.processInfo.environment
    var url: URL { URL(string: environment["AGENTS_WALK610_URL"]!)! }
    var home: String { environment["AGENTS_WALK610_HOME"]! }
    var tool: String { environment["AGENTS_WALK610_TOOL"]! }
    /// The scratch control plane's pid: its tunnels' sockets are in a folder named by it,
    /// so nothing of another control plane's is touched.
    var tunnels: String { "/tmp/agents-tunnels-\(getuid())-\(environment["AGENTS_WALK610_CONTROL_PID"]!)/" }

    func note(_ line: String) { print("WALK610 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

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

    func devbox(_ command: String) throws -> String {
        try run("/usr/bin/env", ["docker", "exec", "-u", "agents", "agents-devbox", "sh", "-c", command]).1
    }

    /// The box with no host on it, as for a first install.
    func fresh() throws {
        _ = try devbox(#"p=$(cat ~/.agents-server/root/daemon.lock 2>/dev/null); [ -n "$p" ] && kill $p; sleep 1; rm -rf ~/.agents-server"#)
    }

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
                                                                id: client, publicKey: key.publicKey, name: "walk610 window", kind: .mac)))))
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

    func host(_ control: DaemonClient, named name: String) async -> DaemonAPI.ControlHost? {
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

    /// Install as the sheet does: once, and again with the fingerprint if one is shown.
    func add(_ control: DaemonClient, _ destination: String, name: String, tunnel: Bool? = nil,
             expectTrust: Bool) async throws -> JSONValue {
        try fresh()
        var params: [String: JSONValue] = ["destination": .string(destination), "name": .string(name)]
        if let tunnel { params["tunnel"] = .bool(tunnel) }
        var answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
        if let fingerprint = answer["needsTrust"]?.stringValue {
            note("\(name): host key shown, \(fingerprint)")
            #expect(expectTrust, "\(name) asked to trust a key it should know")
            params["trust"] = .string(fingerprint)
            answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
        } else {
            #expect(!expectTrust, "\(name) did not show its key")
        }
        note("\(name): \(answer)")
        _ = await within(90, "\(name) online") { await host(control, named: name)?.state == "online" }
        return answer
    }

    func remove(_ control: DaemonClient, _ name: String) async throws {
        while let host = await host(control, named: name) {
            _ = try await control.call(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host.id))
        }
    }

    func tunnelProcesses() throws -> String {
        try run("/bin/sh", ["-c", "pgrep -fl -- '-S \(tunnels)' || true"]).1
    }

    @Test func walk() async throws {
        let (link, control) = try await window()
        defer { link.disconnect() }

        // The server box: the config's hosts, resolved, with no network.
        let offered = try await control.call(DaemonAPI.Method.hostsSSHHosts, JSONValue.object([:]),
                                             returning: [DaemonAPI.SSHHost].self)
        note("offered: \(offered.map { "\($0.alias) → \($0.resolved)\($0.throughBastion ? " (bastion)" : "")\($0.isBastion ? " [way in]" : "")" })")
        #expect(offered.first { $0.alias == "box-behind" }?.throughBastion == true)
        #expect(offered.first { $0.alias == "jump" }?.isBastion == true)
        let typed = try await control.call(DaemonAPI.Method.hostsSSHHosts, ["destination": "agents@127.0.0.1:2222"],
                                           returning: [DaemonAPI.SSHHost].self)
        #expect(typed.first?.resolved == "agents@127.0.0.1:2222")

        // A known host: straight on, no key shown, no tunnel.
        let known = try await add(control, "box", name: "w610-known", expectTrust: false)
        #expect(known["tunnel"]?.boolValue == false)

        // An unknown host: its key is shown, trusted, and the install goes on.
        _ = try await add(control, "box-new", name: "w610-new", expectTrust: true)

        // Behind a bastion, with forwards of its own in the config: a tunnel by default, and
        // only ours on it.
        let behind = try await add(control, "box-behind", name: "w610-behind", expectTrust: false)
        #expect(behind["tunnel"]?.boolValue == true)
        _ = await within(30, "w610-behind's tunnel up") { await host(control, named: "w610-behind")?.tunnel?.up == true }
        note("tunnel ssh on this Mac: \(try tunnelProcesses())")

        // The tunnel drops: it comes back by itself, and so does the host.
        _ = try run("/bin/sh", ["-c", "pkill -f -- '-M -N -S \(tunnels)' || true"])
        note("tunnel ssh killed")
        _ = await within(30, "w610-behind's tunnel seen down") { await host(control, named: "w610-behind")?.tunnel?.up == false }
        _ = await within(60, "w610-behind's tunnel back") { await host(control, named: "w610-behind")?.tunnel?.up == true }
        _ = await within(90, "w610-behind back online") { await host(control, named: "w610-behind")?.state == "online" }

        // One server here, under two names: the old tunnel would hold the port the new one
        // needs, so it goes with its host first (a real second server has its own port).
        try await remove(control, "w610-behind")
        _ = await within(40, "w610-behind's tunnel gone") { ((try? tunnelProcesses()) ?? "x").isEmpty }

        // A direct host that asks for a tunnel.
        let direct = try await add(control, "box", name: "w610-direct-tunnel", tunnel: true, expectTrust: false)
        #expect(direct["tunnel"]?.boolValue == true)
        _ = await within(30, "w610-direct-tunnel's tunnel up") { await host(control, named: "w610-direct-tunnel")?.tunnel?.up == true }

        // Removed: every tunnel goes with its host.
        for name in ["w610-known", "w610-new", "w610-direct-tunnel"] { try await remove(control, name) }
        _ = await within(40, "no tunnel ssh left") { ((try? tunnelProcesses()) ?? "x").isEmpty }
        try fresh()
    }
}
