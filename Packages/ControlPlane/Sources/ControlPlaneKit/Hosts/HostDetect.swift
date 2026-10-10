import AgentsKit
import AgentsKitCore
import Foundation

/// `hosts/detect` (#429): every server in the ssh config that answers, added without
/// being typed in.
///
/// 1. The concrete `Host` names (`SSHConfigHosts`), each resolved by `ssh -G`.
/// 2. Bastions are dropped: a name another entry's `ProxyJump` or `ProxyCommand` goes
///    through is a way in, not a server. Hosts behind one stay, and are probed through it.
/// 3. A host the control plane has by that name is left alone.
/// 4. The rest are probed, a few at once: `BatchMode`, the person's known_hosts,
///    `StrictHostKeyChecking=yes`, a short timeout; a config whose `UserKnownHostsFile` is
///    /dev/null is pointed at ssh's default files instead (#514). One that does not answer
///    is not added.
/// 5. What answered is installed as `hosts/install` would with no key, trusting the host
///    key the person's known_hosts already has. One with Agents installed already is
///    joined the same way (#485): an install left from another control plane, or a join
///    that never finished, is not on this one.
///
/// Only a control plane on the person's Mac has their config, agent and known_hosts.
public struct HostDetect: Sendable {
    public enum Probe: Sendable, Equatable {
        /// It let ssh in; `installed` when Agents is there already.
        case answered(installed: Bool)
        case unreachable(String)
    }

    var aliases: @Sendable () -> [String]
    var resolve: @Sendable (String) async -> SSHConfigHosts.Resolved?
    var probe: @Sendable (String) async -> Probe
    var install: @Sendable (String) async throws -> Void
    var knownNames: @Sendable () async -> [String]

    /// How many ssh connections at once: enough that a dozen dead hosts take one timeout,
    /// few enough not to trip a server's `MaxStartups`.
    static let probes = 8
    static let installs = 2

    init(aliases: @escaping @Sendable () -> [String],
         resolve: @escaping @Sendable (String) async -> SSHConfigHosts.Resolved?,
         probe: @escaping @Sendable (String) async -> Probe,
         install: @escaping @Sendable (String) async throws -> Void,
         knownNames: @escaping @Sendable () async -> [String]) {
        self.aliases = aliases
        self.resolve = resolve
        self.probe = probe
        self.install = install
        self.knownNames = knownNames
    }

    /// The person's own ssh: their `~/.ssh/config` (or `AGENTS_SSH_CONFIG`, for tests),
    /// agent and known_hosts.
    public init(installer: HostInstall, knownNames: @escaping @Sendable () async -> [String]) {
        let config = ProcessInfo.processInfo.environment["AGENTS_SSH_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config")
        let custom = ProcessInfo.processInfo.environment["AGENTS_SSH_CONFIG"] != nil
        let file = custom ? ["-F", config.path] : []
        self.init(
            aliases: { SSHConfigHosts.aliases(in: config) },
            resolve: { alias in
                let ssh = Self.ssh(alias, options: file)
                guard let out = try? await ssh.run(file + ssh.resolveArguments), out.status == 0 else { return nil }
                return SSHConfigHosts.Resolved(alias: alias, output: out.stdout)
            },
            probe: { alias in
                var ssh = Self.ssh(alias, options: file + ["-o", "StrictHostKeyChecking=yes"])
                ssh.options += await HostInstall.personsKnownHosts(ssh)
                let installer = ServerInstaller(ssh: ssh)
                do {
                    let facts = try await Self.within(.seconds(30)) { try await installer.probe() }
                    return .answered(installed: facts.installedSHA256 != nil)
                } catch let problem as HostProblem {
                    return .unreachable(HostInstall.say(problem, keyGiven: false))
                } catch {
                    return .unreachable("It did not answer.")
                }
            },
            install: { alias in
                _ = try await installer.run(HostInstall.Request(destination: alias), personsKnownHosts: true)
            },
            knownNames: knownNames)
    }

    private static func ssh(_ alias: String, options: [String]) -> SSHCommand {
        var ssh = SSHCommand(executable: HostInstall.sshExecutable, name: alias, controlPath: nil,
                             environment: HostInstall.environment(keepAgent: true))
        ssh.options = options
        return ssh
    }

    public func run() async -> [DaemonAPI.DetectedServer] {
        let names = aliases()
        let resolved = await Self.each(names, limit: Self.probes) { alias in
            await resolve(alias) ?? SSHConfigHosts.Resolved(alias: alias, options: [:])
        }
        let bastions = SSHConfigHosts.bastions(resolved)
        let known = Set(await knownNames().map { $0.lowercased() })

        var results: [String: DaemonAPI.DetectedServer] = [:]
        var toProbe: [SSHConfigHosts.Resolved] = []
        for host in resolved {
            if SSHConfigHosts.isBastion(host, among: bastions) {
                results[host.alias] = .init(alias: host.alias, resolved: host.display, outcome: .bastion,
                                            detail: "Other hosts are reached through it.")
            } else if known.contains(host.alias.lowercased()) || known.contains(host.hostName.lowercased()) {
                results[host.alias] = .init(alias: host.alias, resolved: host.display, outcome: .known,
                                            detail: "Already a host.")
            } else {
                toProbe.append(host)
            }
        }

        let probed = await Self.each(toProbe, limit: Self.probes) { host in (host, await probe(host.alias)) }
        var toInstall: [SSHConfigHosts.Resolved] = []
        for (host, answer) in probed {
            switch answer {
            case .answered:
                toInstall.append(host)
            case .unreachable(let why):
                results[host.alias] = .init(alias: host.alias, resolved: host.display, outcome: .unreachable, detail: why)
            }
        }

        let installed = await Self.each(toInstall, limit: Self.installs) { host -> DaemonAPI.DetectedServer in
            do {
                try await install(host.alias)
                return .init(alias: host.alias, resolved: host.display, outcome: .added)
            } catch let error as JSONRPCError {
                return .init(alias: host.alias, resolved: host.display, outcome: .failed, detail: error.message)
            } catch {
                return .init(alias: host.alias, resolved: host.display, outcome: .failed, detail: "\(error)")
            }
        }
        for server in installed { results[server.alias] = server }
        return names.compactMap { results[$0] }
    }

    /// `work` on each item, at most `limit` at once, the results in the items' order.
    static func each<T: Sendable, R: Sendable>(_ items: [T], limit: Int,
                                               _ work: @escaping @Sendable (T) async -> R) async -> [R] {
        await withTaskGroup(of: (Int, R).self) { group in
            var results = [R?](repeating: nil, count: items.count)
            var next = 0
            for _ in 0..<min(limit, items.count) {
                let index = next
                group.addTask { (index, await work(items[index])) }
                next += 1
            }
            for await (index, result) in group {
                results[index] = result
                if next < items.count {
                    let index = next
                    group.addTask { (index, await work(items[index])) }
                    next += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    /// `work`, or a timeout when it takes longer: ssh's own `ConnectTimeout` does not
    /// cover a `ProxyCommand` that hangs. Not a task group, which would wait for an ssh
    /// that does not hear cancellation; that one is left to end by itself.
    static func within<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { continuation in
            once.set(continuation)
            Task { once.resume(with: await Result(catching: work)) }
            Task {
                try? await Task.sleep(for: limit)
                once.resume(with: .failure(HostProblem.timedOut("It did not answer in time.")))
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, any Error>?
        private var early: Result<T, any Error>?

        func set(_ continuation: CheckedContinuation<T, any Error>) {
            let ready = lock.withLock { () -> Result<T, any Error>? in
                if let early { return early }
                self.continuation = continuation
                return nil
            }
            if let ready { continuation.resume(with: ready) }
        }

        func resume(with result: Result<T, any Error>) {
            let waiting = lock.withLock { () -> CheckedContinuation<T, any Error>? in
                defer { continuation = nil }
                if continuation == nil, early == nil { early = result }
                return continuation
            }
            waiting?.resume(with: result)
        }
    }
}

private extension Result where Failure == any Error {
    init(catching body: () async throws -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
}
