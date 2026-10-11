import AgentsKit
import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// One ssh path for adding servers (#610), against a real sshd: the devbox
/// (`test-servers` skill, `devbox.sh up`). Only when `AGENTS_SSH_LIVE` is set.
///
/// Each test writes an ssh config of its own, read with `-F`, so the person's
/// `~/.ssh/config` and `~/.ssh/known_hosts` are never read or written.
@Suite("One ssh path, live against the devbox", .enabled(if: ProcessInfo.processInfo.environment["AGENTS_SSH_LIVE"] != nil),
       .serialized)
struct SSHPathLiveTests {
    /// `devbox.sh` keeps the box's host keys here, outside the person's known_hosts.
    static let knownHosts = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/agents-devbox/known_hosts").path

    /// A config entry for the box, with whatever else the test wants in it.
    static func config(_ extra: String, knownHosts: String = knownHosts) throws -> (folder: URL, file: [String]) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("config")
        try """
        Host box
          HostName 127.0.0.1
          Port 2222
          User agents
          IdentityFile ~/.ssh/id_ed25519
          IdentitiesOnly yes
          UserKnownHostsFile \(knownHosts)
        \(extra)
        """.write(to: file, atomically: true, encoding: .utf8)
        return (folder, ["-F", file.path])
    }

    static func record(port: Int) -> HostTunnels.Record {
        .init(id: UUID().uuidString.lowercased(), destination: "box", name: "box", port: port,
              code: UUID().uuidString.lowercased(), host: HostID(rawValue: "box"), knownHosts: "", made: Date())
    }

    static func tunnels(_ file: [String], heard: HostTunnelsTests.Heard) -> HostTunnels {
        HostTunnels(store: MemoryStore(), executable: SSHCommand.system,
                    environment: SSHCommand.environment(from: ProcessInfo.processInfo.environment),
                    hosts: { [HostRecord(id: HostID(rawValue: "box"), name: "box")] },
                    changed: { await heard.add($0) }, configFile: file)
    }

    /// A config entry with every forward kind, a `RemoteForward` that cannot open (sshd has
    /// port 22), a `RemoteCommand` and `RequestTTY force`: the tunnel opens anyway, with only
    /// its own forward.
    @Test func theTunnelOpensOnlyItsOwnForward() async throws {
        let localForward = 18_000 + Int.random(in: 0..<900)
        let (folder, file) = try Self.config("""
          RemoteForward 127.0.0.1:22 127.0.0.1:9
          LocalForward 127.0.0.1:\(localForward) 127.0.0.1:22
          DynamicForward 127.0.0.1:\(localForward + 1)
          RemoteCommand echo not-for-us
          RequestTTY force
          ExitOnForwardFailure yes
          ControlMaster auto
          ControlPath \(FileManager.default.temporaryDirectory.path)/never-%C
          ControlPersist 600
        """)
        defer { try? FileManager.default.removeItem(at: folder) }
        let heard = HostTunnelsTests.Heard()
        let tunnels = Self.tunnels(file, heard: heard)
        let port = 18_900 + Int.random(in: 0..<90)
        try await tunnels.add(Self.record(port: port))
        try await heard.waitFor { $0.contains { $0.tunnel.up } }
        #expect(await tunnels.state(for: HostID(rawValue: "box")) == .init(up: true))

        // The server's end listens; the config's forwards were not opened here.
        var probe = SSHCommand(name: "box", controlPath: nil)
        probe.options = file
        let listening = try await probe.run(probe.runArguments("bash -c 'exec 3<>/dev/tcp/127.0.0.1/\(port)' && echo open"))
        #expect(listening.stdout == "open\n", "\(listening)")
        let local = try await SSHCommand(executable: URL(fileURLWithPath: "/usr/sbin/lsof"), name: "", controlPath: nil)
            .run(["-nP", "-iTCP:\(localForward)", "-iTCP:\(localForward + 1)", "-sTCP:LISTEN"])
        #expect(local.stdout.isEmpty, "\(local.stdout)")
        await tunnels.stop()
    }

    /// The server will not open the forward (its port 22 is sshd's): the session ends with
    /// ssh's words for it, not "hasn't joined".
    @Test func aRefusedForwardEndsTheSessionWithSSHsReason() async throws {
        let (folder, file) = try Self.config("")
        defer { try? FileManager.default.removeItem(at: folder) }
        let heard = HostTunnelsTests.Heard()
        let tunnels = Self.tunnels(file, heard: heard)
        try await tunnels.add(Self.record(port: 22))
        try await heard.waitFor { !$0.isEmpty }
        let state = await tunnels.state(for: HostID(rawValue: "box"))
        #expect(state?.up == false)
        #expect(state?.problem?.contains("remote port forwarding failed for listen port 22") == true, "\(String(describing: state))")
        await tunnels.stop()
    }

    static func installer(_ file: [String]) -> HostInstall {
        let codes = ControlCodes.forCommandLine(store: MemoryStore(), privateKey: ControlAgreement.generate().privateKey,
                                                url: "https://127.0.0.1:1", pin: nil, name: "live")
        // No servers folder: the install stops once ssh has logged in and read the system.
        return HostInstall(codes: codes, servers: FileManager.default.temporaryDirectory.appendingPathComponent("no-servers-\(UUID())"),
                           configFile: file)
    }

    static func stoppedAtTheSystem(_ work: () async throws -> JSONValue) async -> Bool {
        do {
            _ = try await work()
            return false
        } catch {
            return ((error as? JSONRPCError)?.message ?? "").contains("which this control plane has no host for")
        }
    }

    @Test func aKnownHostIsInstalledWithoutAsking() async throws {
        let (folder, file) = try Self.config("")
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(await Self.stoppedAtTheSystem { try await Self.installer(file).run(["destination": "box"]) })
    }

    @Test func anUnknownHostIsShownThenTrusted() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString)")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        let (folder, file) = try Self.config("", knownHosts: empty.path)
        defer { try? FileManager.default.removeItem(at: folder) }
        let install = Self.installer(file)
        let asked = try await install.run(["destination": "box"])
        let fingerprint = try #require(asked["needsTrust"]?.stringValue)
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(await Self.stoppedAtTheSystem { try await install.run(["destination": "box", "trust": .string(fingerprint)]) })
        // The person's file (here, the config's) is left as it was.
        #expect(try Data(contentsOf: empty).isEmpty)
    }

    @Test func aChangedKeyIsRefused() async throws {
        let wrong = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString)")
        // Another server's key under the box's name.
        try "[127.0.0.1]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl\n"
            .write(to: wrong, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: wrong) }
        let (folder, file) = try Self.config("", knownHosts: wrong.path)
        defer { try? FileManager.default.removeItem(at: folder) }
        await #expect {
            _ = try await Self.installer(file).run(["destination": "box"])
        } throws: { error in
            ((error as? JSONRPCError)?.message ?? "").contains("has changed")
        }
    }
}
