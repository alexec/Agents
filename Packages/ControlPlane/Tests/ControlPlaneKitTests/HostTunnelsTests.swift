import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// A server behind a bastion dials the control plane through a reverse tunnel held over
/// ssh (#435); one on the same network dials it directly, as before.
@Suite("Reverse tunnels for servers behind a bastion")
struct HostTunnelsTests {
    @Test func aProxyJumpOrProxyCommandIsABastion() {
        #expect(SSHCommand.throughBastion("user agents\nhostname ws.svc.cluster.local\nproxyjump bastion\nport 22\n"))
        #expect(SSHCommand.throughBastion("hostname ws\nproxycommand ssh -W %h:%p bastion\n"))
        // `ssh -G` says `none` for a name its config sends straight there.
        #expect(!SSHCommand.throughBastion("hostname devbox.lan\nproxycommand none\nport 2222\n"))
        #expect(!SSHCommand.throughBastion("hostname devbox.lan\nport 22\n"))
    }

    @Test func theTunnelIsAMasterOfItsOwnThatOpensNoForwardOfTheConfigs() {
        let ssh = SSHCommand(name: "agents@ws:2222", controlPath: nil)
        let control = URL(fileURLWithPath: "/tmp/agents-tunnels-1-2/abcd1234.ctl")
        let master = ssh.tunnelMasterArguments(control: control)
        #expect(master.contains("-M") && master.contains("-N"))
        #expect(Array(master.drop { $0 != "-S" }.prefix(2)) == ["-S", "/tmp/agents-tunnels-1-2/abcd1234.ctl"])
        #expect(master.contains("ControlPersist=no"))
        #expect(master.contains("ExitOnForwardFailure=yes"))
        #expect(master.contains("BatchMode=yes"))
        // #610: the config's LocalForward, RemoteForward and DynamicForward are not opened,
        // and its RemoteCommand and RequestTTY cannot break -N.
        #expect(master.contains("ClearAllForwardings=yes"))
        #expect(master.contains("RemoteCommand=none"))
        #expect(master.contains("RequestTTY=no"))
        // ClearAllForwardings clears a -R on the command line too, so there is none here…
        #expect(!master.contains("-R") && !master.contains("-L") && !master.contains("-D"))
        #expect(Array(master.suffix(2)) == ["--", "ssh://agents@ws:2222"])
        // …and the one forward is asked of the master.
        #expect(ssh.tunnelForwardArguments(control: control, remotePort: 8791, localPort: 8792) == [
            "-S", "/tmp/agents-tunnels-1-2/abcd1234.ctl", "-O", "forward",
            "-R", "127.0.0.1:8791:127.0.0.1:8792", "--", "ssh://agents@ws:2222"])
        #expect(ssh.tunnelControlArguments(control: control, "check") == [
            "-S", "/tmp/agents-tunnels-1-2/abcd1234.ctl", "-O", "check", "--", "ssh://agents@ws:2222"])
    }

    @Test func aRefusedForwardIsSaidInSSHsWords() {
        #expect(HostTunnels.forwardFailure("""
            mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 8791
            muxclient: master forward request failed
            """) == "remote port forwarding failed for listen port 8791")
        #expect(HostTunnels.forwardFailure("debug1: x\nControl socket connect(/tmp/x.ctl): No such file or directory\n")
            == "Control socket connect(/tmp/x.ctl): No such file or directory")
        #expect(HostTunnels.forwardFailure("") == "the server would not open the tunnel's forward")
    }

    @Test func onlySSHsOwnWordsAreKeptAsTheReason() {
        #expect(HostTunnels.SessionLines.said("debug1: Connecting to ws port 22.") == nil)
        #expect(HostTunnels.SessionLines.said("OpenSSH_9.8p1, LibreSSL 3.3.6") == nil)
        #expect(HostTunnels.SessionLines.said("Warning: remote port forwarding failed for listen port 8791")
            == "remote port forwarding failed for listen port 8791")
        #expect(HostTunnels.SessionLines.said("agents@ws: Permission denied (publickey).") == "agents@ws: Permission denied (publickey).")
    }

    @Test func aSessionIsUpWhenTheForwardIsOpenAndDownWithSSHsReasonWhenItIsRefused() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("argv")
        let up = try Self.fakeSSH(in: folder, named: "up", log: log, forward: "exit 0", master: "exec sleep 30")
        let heard = Heard()
        let host = HostID(rawValue: "ws")
        let tunnels = HostTunnels(store: MemoryStore(), executable: up, environment: [:],
                                  hosts: { [HostRecord(id: host, name: "ws")] }, changed: { await heard.add($0) })
        try await tunnels.add(Self.record(host: host))
        try await heard.waitFor { $0.contains { $0.tunnel.up } }
        #expect(await tunnels.state(for: host) == .init(up: true))
        await tunnels.stop()
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.contains("-O forward -R 127.0.0.1:8791:127.0.0.1:8791"))
        #expect(calls.contains("ClearAllForwardings=yes"))

        // The server will not open it: the master is ended, and the reason is ssh's.
        let refused = try Self.fakeSSH(in: folder, named: "refused", forward: """
            echo "mux_client_forward: forwarding request failed: remote port forwarding failed for listen port 8791" >&2
            echo "muxclient: master forward request failed" >&2
            exit 255
            """, master: "exec sleep 30")
        let failing = Heard()
        let other = HostTunnels(store: MemoryStore(), executable: refused, environment: [:],
                                hosts: { [HostRecord(id: host, name: "ws")] }, changed: { await failing.add($0) })
        try await other.add(Self.record(host: host))
        try await failing.waitFor { !$0.isEmpty }
        #expect(await other.state(for: host) == .init(up: false, problem: "remote port forwarding failed for listen port 8791"))
        await other.stop()

        // ssh itself gave up: its own last words.
        let denied = try Self.fakeSSH(in: folder, named: "denied", forward: "exit 255", master: """
            echo "agents@ws: Permission denied (publickey)." >&2
            exit 255
            """)
        let refusing = Heard()
        let third = HostTunnels(store: MemoryStore(), executable: denied, environment: [:],
                                hosts: { [HostRecord(id: host, name: "ws")] }, changed: { await refusing.add($0) })
        try await third.add(Self.record(host: host))
        try await refusing.waitFor { !$0.isEmpty }
        #expect(await third.state(for: host) == .init(up: false, problem: "agents@ws: Permission denied (publickey)."))
        await third.stop()
    }

    @Test func aWakeStartsEverySessionAgain() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("argv")
        let ssh = try Self.fakeSSH(in: folder, named: "up", log: log, forward: "exit 0", master: "exec sleep 30")
        let heard = Heard()
        let host = HostID(rawValue: "ws")
        let tunnels = HostTunnels(store: MemoryStore(), executable: ssh, environment: [:],
                                  hosts: { [HostRecord(id: host, name: "ws")] }, changed: { await heard.add($0) })
        try await tunnels.add(Self.record(host: host))
        try await heard.waitFor { $0.contains { $0.tunnel.up } }
        await tunnels.restart(because: "this Mac woke")
        try await Self.eventually { (try? String(contentsOf: log, encoding: .utf8))?.components(separatedBy: "-O forward").count == 3 }
        await tunnels.stop()
    }

    @Test func aTunnelLearnsItsHostFromTheCodeAndGoesWhenTheHostDoes() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = try Self.fakeSSH(in: folder, named: "sleep", forward: "exit 0", master: "exec sleep 30")
        let store = MemoryStore()
        let host = HostID(rawValue: "ws")
        let known = Known([HostRecord(id: host, name: "ws")])
        let tunnels = HostTunnels(store: store, executable: sleeper, environment: [:],
                                  hosts: { await known.records }, changed: { _ in })
        let record = Self.record(host: nil)
        try await tunnels.add(record)
        #expect(await tunnels.state(for: host) == nil)
        // Not joined yet: listed by name, so the window can say how it stands (#660).
        #expect(await tunnels.unjoined().map(\.name) == ["ws"])

        // The host's join spends the code: the tunnel is that host's from then on.
        _ = try await store.put(ControlCodes.key(record.code), Data("{}".utf8), when: .absent)
        _ = try await store.put(ControlCodes.spentKey(record.code),
                                try ControlRecords.encoder.encode(ControlCodes.Spent(publicKey: Data([1]), host: host)), when: .absent)
        await tunnels.reconcile()
        #expect(await tunnels.state(for: host) != nil)
        #expect(await tunnels.unjoined().isEmpty)

        // Removed: the tunnel and its record go.
        await known.set([])
        await tunnels.reconcile()
        #expect(await tunnels.state(for: host) == nil)
        #expect(try await store.list(prefix: HostTunnels.prefix).isEmpty)
        await tunnels.stop()
    }

    @Test func theSameServerAddedAgainLetsItsOldTunnelGo() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = try Self.fakeSSH(in: folder, named: "sleep", forward: "exit 0", master: "exec sleep 30")
        let store = MemoryStore()
        let tunnels = HostTunnels(store: store, executable: sleeper, environment: [:], hosts: { [] }, changed: { _ in })
        let first = Self.record(host: nil)
        try await tunnels.add(first)
        var second = Self.record(host: nil)
        second.destination = "AGENTS@ws"
        try await tunnels.add(second)
        #expect(try await store.list(prefix: HostTunnels.prefix).map(\.key) == [HostTunnels.key(second.id)])
        await tunnels.stop()
    }

    /// A server through a tunnel dials this listener at its loopback (#435, #610).
    @Test func aCopyThatHoldsTunnelsAnswersAtItsLoopbackToo() {
        let settings = ControlSettings(name: "home", machineID: "m")
        #expect(ControlService.origins("https://mac.local:8791", settings) == ["https://mac.local:8791"])
        #expect(ControlService.origins("https://mac.local:8791", settings, tunnelled: 8791)
            == ["https://mac.local:8791", "https://127.0.0.1:8791"])
    }

    @Test func aServerThatNeverJoinedIsLetGo() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = try Self.fakeSSH(in: folder, named: "sleep", forward: "exit 0", master: "exec sleep 30")
        let store = MemoryStore()
        var stale = Self.record(host: nil)
        stale.made = Date().addingTimeInterval(-HostTunnels.unjoinedKept - 1)
        _ = try await store.put(HostTunnels.key(stale.id), try ControlRecords.encoder.encode(stale), when: .absent)
        let tunnels = HostTunnels(store: store, executable: sleeper, environment: [:], hosts: { [] }, changed: { _ in })
        await tunnels.reconcile()
        #expect(try await store.list(prefix: HostTunnels.prefix).isEmpty)
        await tunnels.stop()
    }

    // MARK: Helpers

    static func record(host: HostID?) -> HostTunnels.Record {
        .init(id: UUID().uuidString.lowercased(), destination: "agents@ws", name: "ws", port: 8791,
              code: UUID().uuidString.lowercased(), host: host, knownHosts: "ws ssh-ed25519 AAAA\n", made: Date())
    }

    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("tunnels-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A stand-in for ssh: `-O check` answers, `-O forward` runs `forward`, and anything
    /// else is the master, running `master`. Every call's arguments go to `log`.
    static func fakeSSH(in folder: URL, named name: String, log: URL? = nil, forward: String, master: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        let logging = log.map { "printf '%s\\n' \"$*\" >> '\($0.path)'\n" } ?? ""
        try Data("""
            #!/bin/sh
            \(logging)op=""
            for word in "$@"; do [ "$previous" = "-O" ] && op="$word"; previous="$word"; done
            case "$op" in
                check) exit 0 ;;
                forward)
            \(forward)
                ;;
            esac
            \(master)

            """.utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
    }

    static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() { try await Task.sleep(for: .milliseconds(50)) }
        #expect(condition())
    }

    actor Heard {
        private(set) var changes: [DaemonAPI.HostTunnelChanged] = []
        func add(_ change: DaemonAPI.HostTunnelChanged) { changes.append(change) }
        func waitFor(_ condition: ([DaemonAPI.HostTunnelChanged]) -> Bool) async throws {
            for _ in 0..<100 where !condition(changes) { try await Task.sleep(for: .milliseconds(50)) }
            #expect(condition(changes))
        }
    }

    actor Known {
        private(set) var records: [HostRecord]
        init(_ records: [HostRecord]) { self.records = records }
        func set(_ records: [HostRecord]) { self.records = records }
    }
}
