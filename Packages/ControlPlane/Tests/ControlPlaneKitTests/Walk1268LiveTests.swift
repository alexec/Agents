import AgentsKit
import AgentsKitCore
import ControlDial
@testable import ControlPlaneKit
import Foundation
import Testing

/// The walk for #1268, against the devbox (test-servers): `hosts/install` on a scratch
/// control plane puts Claude's toolset on the server before the host starts, for the Swift
/// host and the Go one. The devbox has no xz, curl or wget, so Node comes from the control
/// plane. The control plane is started with `AGENTS_CONTROL_TOOLSETS` and
/// `AGENTS_SSH_CONFIG` (a config whose `box` is the devbox). Only when
/// `AGENTS_WALK1268_URL` is set.
///
///   AGENTS_WALK1268_URL=https://<LAN address>:<port> AGENTS_WALK1268_HOME=/tmp/run-x/control \
///   AGENTS_WALK1268_TOOL=<agents-control> swift test --filter Walk1268
@Suite("Walk #1268: Claude's toolset on a server", .serialized, .timeLimit(.minutes(10)),
       .enabled(if: ProcessInfo.processInfo.environment["AGENTS_WALK1268_URL"] != nil))
struct Walk1268LiveTests {
    let environment = ProcessInfo.processInfo.environment
    var url: URL { URL(string: environment["AGENTS_WALK1268_URL"]!)! }
    var home: String { environment["AGENTS_WALK1268_HOME"]! }
    var tool: String { environment["AGENTS_WALK1268_TOOL"]! }

    func note(_ line: String) { print("WALK1268 \(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) \(line)") }

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

    /// The box with no host and no toolset on it, as for a first install.
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
                                                                id: client, publicKey: key.publicKey, name: "walk1268 window", kind: .mac)))))
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

    @Test(arguments: ["swift", "go"])
    func aFirstInstallPutsClaudesToolsetOnTheServer(implementation: String) async throws {
        let (link, control) = try await window()
        defer { link.disconnect() }
        try fresh()
        let name = "w1268-\(implementation)"
        var params: [String: JSONValue] = ["destination": "box", "name": .string(name), "tunnel": false,
                                           "implementation": .string(implementation)]
        let started = Date()
        var answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
        if let fingerprint = answer["needsTrust"]?.stringValue {
            params["trust"] = .string(fingerprint)
            answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
        }
        note("\(name): \(answer) in \(Int(Date().timeIntervalSince(started))) s")
        #expect(answer["started"] == true)

        // The pinned toolset, whole, with current pointed at it.
        let folder = try #require(HostToolsets.folder())
        let id = try Toolset.load(from: folder.appendingPathComponent("claude")).id
        let current = try devbox(#"T=~/.agents-server/tools/claude; [ -f "$T/current/ok" ] && readlink "$T/current"; du -sm "$T/current/" | cut -f1"#)
        note("\(name): current \(current.split(separator: "\n").joined(separator: ", ")) MB")
        #expect(current.split(separator: "\n").first.map(String.init) == id)

        // The shim answers an ACP initialize with the toolset's own Node.
        let initialize = try devbox(#"printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":1,"clientCapabilities":{}}}' | timeout 30 ~/.agents-server/tools/claude/current/bin/npx 2>/dev/null | head -1"#)
        note("\(name): initialize \(initialize.prefix(200))")
        #expect(initialize.contains(#""protocolVersion""#))

        _ = await within(90, "\(name) online") { await host(control, named: name)?.state == "online" }
        let running = try devbox(#"ps -o args= -p "$(cat ~/.agents-server/root/daemon.lock)""#)
        note("\(name): host \(running.trimmingCharacters(in: .whitespacesAndNewlines))")
        while let host = await host(control, named: name) {
            _ = try await control.call(DaemonAPI.Method.hostsRemove, DaemonAPI.HostRequest(host: host.id))
        }
        try fresh()
    }
}
