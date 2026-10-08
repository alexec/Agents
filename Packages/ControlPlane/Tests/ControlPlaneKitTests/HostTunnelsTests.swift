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

    @Test func theTunnelIsItsOwnConnectionToTheServersLoopback() {
        let ssh = SSHCommand(name: "agents@ws:2222", controlPath: nil)
        let arguments = ssh.reverseTunnelArguments(remotePort: 8791, localPort: 8791)
        #expect(arguments.contains("-N"))
        #expect(arguments.contains("ControlPath=none"))
        #expect(arguments.contains("ExitOnForwardFailure=yes"))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(Array(arguments.suffix(4)) == ["-R", "127.0.0.1:8791:127.0.0.1:8791", "--", "ssh://agents@ws:2222"])
    }

    @Test func onlySSHsOwnWordsAreKeptAsTheReason() {
        #expect(HostTunnels.SessionLines.said("debug1: Connecting to ws port 22.") == nil)
        #expect(HostTunnels.SessionLines.said("OpenSSH_9.8p1, LibreSSL 3.3.6") == nil)
        #expect(HostTunnels.SessionLines.said("Warning: remote port forwarding failed for listen port 8791")
            == "remote port forwarding failed for listen port 8791")
        #expect(HostTunnels.SessionLines.said("agents@ws: Permission denied (publickey).") == "agents@ws: Permission denied (publickey).")
    }

    @Test func aSessionIsUpWhenTheForwardIsOpenAndDownWithSSHsReasonWhenItEnds() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let up = try Self.fakeSSH(in: folder, named: "up", """
            echo "debug1: remote forward success for: listen 127.0.0.1:8791, connect 127.0.0.1:8791" >&2
            exec sleep 30
            """)
        let heard = Heard()
        let host = HostID(rawValue: "ws")
        let store = MemoryStore()
        let tunnels = HostTunnels(store: store, executable: up, environment: [:],
                                  hosts: { [HostRecord(id: host, name: "ws")] }, changed: { await heard.add($0) })
        try await tunnels.add(Self.record(host: host))
        try await heard.waitFor { $0.contains { $0.tunnel.up } }
        #expect(await tunnels.state(for: host) == .init(up: true))
        await tunnels.stop()

        let down = try Self.fakeSSH(in: folder, named: "down", """
            echo "Warning: remote port forwarding failed for listen port 8791" >&2
            exit 255
            """)
        let failing = Heard()
        let other = HostTunnels(store: MemoryStore(), executable: down, environment: [:],
                                hosts: { [HostRecord(id: host, name: "ws")] }, changed: { await failing.add($0) })
        try await other.add(Self.record(host: host))
        try await failing.waitFor { !$0.isEmpty }
        #expect(await other.state(for: host) == .init(up: false, problem: "remote port forwarding failed for listen port 8791"))
        await other.stop()
    }

    @Test func aTunnelLearnsItsHostFromTheCodeAndGoesWhenTheHostDoes() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = try Self.fakeSSH(in: folder, named: "sleep", "exec sleep 30")
        let store = MemoryStore()
        let host = HostID(rawValue: "ws")
        let known = Known([HostRecord(id: host, name: "ws")])
        let tunnels = HostTunnels(store: store, executable: sleeper, environment: [:],
                                  hosts: { await known.records }, changed: { _ in })
        let record = Self.record(host: nil)
        try await tunnels.add(record)
        #expect(await tunnels.state(for: host) == nil)

        // The host's join spends the code: the tunnel is that host's from then on.
        _ = try await store.put(ControlCodes.key(record.code), Data("{}".utf8), when: .absent)
        _ = try await store.put(ControlCodes.spentKey(record.code),
                                try ControlRecords.encoder.encode(ControlCodes.Spent(publicKey: Data([1]), host: host)), when: .absent)
        await tunnels.reconcile()
        #expect(await tunnels.state(for: host) != nil)

        // Removed: the tunnel and its record go.
        await known.set([])
        await tunnels.reconcile()
        #expect(await tunnels.state(for: host) == nil)
        #expect(try await store.list(prefix: HostTunnels.prefix).isEmpty)
        await tunnels.stop()
    }

    @Test func aServerThatNeverJoinedIsLetGo() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let sleeper = try Self.fakeSSH(in: folder, named: "sleep", "exec sleep 30")
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

    /// A stand-in for ssh that says what the real one would on standard error.
    static func fakeSSH(in folder: URL, named name: String, _ body: String) throws -> URL {
        let file = folder.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return file
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
