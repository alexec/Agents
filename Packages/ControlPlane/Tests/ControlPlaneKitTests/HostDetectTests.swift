import AgentsKitCore
@testable import ControlPlaneKit
import Foundation
import Testing

/// Servers from the ssh config (#429).
@Suite("Servers found in ~/.ssh/config")
struct HostDetectTests {
    func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-\(UUID())")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("config.d"), withIntermediateDirectories: true)
        return folder
    }

    @Test func theConcreteNamesAreReadThroughIncludes() throws {
        let ssh = try folder()
        defer { try? FileManager.default.removeItem(at: ssh) }
        try """
        # defaults
        Host *
            User agents
        Host *.example.com !secret.example.com
            ForwardAgent no
        Include config.d/*
        Host devbox build-1 # two names
            HostName 10.0.0.4
        Host=quoted "with space"
        Match host devbox exec "true"
            Port 2222
        Include config
        """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
        try "Host gpu\n  ProxyJump bastion\nHost bastion\n".write(to: ssh.appendingPathComponent("config.d/b"), atomically: true, encoding: .utf8)
        try "host a\nHOST = devbox\n".write(to: ssh.appendingPathComponent("config.d/a"), atomically: true, encoding: .utf8)

        #expect(SSHConfigHosts.aliases(in: ssh.appendingPathComponent("config"), home: ssh)
            == ["a", "devbox", "gpu", "bastion", "build-1", "quoted", "with space"])
    }

    @Test func aBastionIsWhatAnotherEntryGoesThrough() {
        let hosts = [
            SSHConfigHosts.Resolved(alias: "gpu", options: ["hostname": "10.1.0.9", "proxyjump": "ops@jump.example.com:2200,bastion"]),
            SSHConfigHosts.Resolved(alias: "old", options: ["hostname": "old.lan", "proxycommand": "ssh -q -W %h:%p gateway"]),
            SSHConfigHosts.Resolved(alias: "nc", options: ["hostname": "nc.lan", "proxycommand": "/usr/bin/ssh -l me -J hop1 relay nc %h %p"]),
            SSHConfigHosts.Resolved(alias: "cf", options: ["proxycommand": "cloudflared access ssh --hostname %h"]),
            SSHConfigHosts.Resolved(alias: "bastion", options: ["hostname": "203.0.113.1", "proxyjump": "none"]),
            SSHConfigHosts.Resolved(alias: "jump", options: ["hostname": "jump.example.com"]),
            SSHConfigHosts.Resolved(alias: "devbox", options: ["hostname": "10.0.0.4", "user": "agents", "port": "2222"]),
        ]
        let bastions = SSHConfigHosts.bastions(hosts)
        #expect(bastions == ["jump.example.com", "bastion", "gateway", "hop1", "relay"])
        let skipped = hosts.filter { SSHConfigHosts.isBastion($0, among: bastions) }.map(\.alias)
        // `jump` by its HostName; the hosts behind them stay candidates.
        #expect(skipped == ["bastion", "jump"])
        #expect(hosts.last?.display == "agents@10.0.0.4:2222")
    }

    @Test func sshDashGIsReadByKeyword() {
        let resolved = SSHConfigHosts.Resolved(alias: "devbox", output: "user agents\nhostname 10.0.0.4\nport 22\nproxyjump bastion\nidentityfile ~/.ssh/a\nidentityfile ~/.ssh/b\n")
        #expect(resolved.display == "agents@10.0.0.4")
        #expect(resolved.options["identityfile"] == "~/.ssh/a")
        #expect(resolved.jumpHosts == ["bastion"])
    }

    @Test func onlyWhatAnswersIsAddedAndBastionsNeverAre() async {
        let installed = DetectLocked<[String]>([])
        let probed = DetectLocked<[String]>([])
        let detect = HostDetect(
            aliases: { ["devbox", "bastion", "gpu", "down", "mine", "had"] },
            resolve: { alias in
                switch alias {
                case "gpu": SSHConfigHosts.Resolved(alias: alias, options: ["hostname": "10.1.0.9", "proxyjump": "bastion"])
                case "down": nil
                default: SSHConfigHosts.Resolved(alias: alias, options: ["hostname": alias + ".lan"])
                }
            },
            probe: { alias in
                probed.with { $0.append(alias) }
                switch alias {
                case "down": return .unreachable("It did not answer.")
                case "had": return .answered(installed: true)
                default: return .answered(installed: false)
                }
            },
            install: { alias in
                if alias == "gpu" { throw JSONRPCError(code: 1, message: "no host for that system") }
                installed.with { $0.append(alias) }
            },
            knownNames: { ["mine.lan"] })

        let results = await detect.run()
        #expect(results.map(\.alias) == ["devbox", "bastion", "gpu", "down", "mine", "had"])
        #expect(results.map(\.outcome) == [.added, .bastion, .failed, .unreachable, .known, .known])
        #expect(results[2].detail == "no host for that system")
        #expect(installed.value == ["devbox"])
        // The bastion answers, and is never probed nor added; a known host is left alone.
        #expect(Set(probed.value) == ["devbox", "gpu", "down", "had"])
    }

    @Test func aHungProbeEndsAtItsLimit() async {
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: HostProblem.self) {
            try await HostDetect.within(.milliseconds(100)) {
                try? await Task.sleep(for: .seconds(5))
                return 1
            }
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test func atMostSoManyAtOnceAndInOrder() async {
        let running = DetectLocked(0), most = DetectLocked(0)
        let out = await HostDetect.each(Array(0..<20), limit: 3) { item in
            let now = running.with { $0 += 1; return $0 }
            most.with { $0 = max($0, now) }
            try? await Task.sleep(for: .milliseconds(10))
            running.with { $0 -= 1 }
            return item * 2
        }
        #expect(out == Array(0..<20).map { $0 * 2 })
        #expect(most.value <= 3)
    }
}

final class DetectLocked<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var held: T
    init(_ value: T) { held = value }
    var value: T { lock.withLock { held } }
    @discardableResult
    func with<R>(_ change: (inout T) -> R) -> R { lock.withLock { change(&held) } }
}
