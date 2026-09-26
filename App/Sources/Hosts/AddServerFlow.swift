import AgentsKit
import Foundation
import Observation

/// What the Add a server sheet is doing (037, contracts/ui.md § Add a server).
///
/// A — a name; B — a new host key to trust; then the four steps; C — ready, with the
/// runtimes found; C′ — ready with none; D — failed, saying why. The host is only
/// recorded once it is ready, so a sheet cancelled or failed part way adds nothing.
@MainActor
@Observable
final class AddServerFlow {
    enum Phase: Equatable {
        case name
        case working(ServerConnection.Step)
        case trust(fingerprint: String)
        case ready(runtimes: [String])
        case failed(HostProblem, at: ServerConnection.Step)
    }

    var name = ""
    private(set) var phase: Phase = .name
    private(set) var host: ServerHost?
    /// Steps already done, for the ticks.
    private(set) var done: [ServerConnection.Step] = []
    private(set) var system: String?
    /// Claude's toolset on the new server (043). Shown as its own step when it installs.
    private(set) var claude: ServerConnection.Claude = .unknown
    /// Whether the checklist has an Install Claude step: the window has a credential for it.
    var installsClaude: Bool { hosts.claudeWanted(host?.id ?? HostID(rawValue: "")) || claudeHasBeenTouched }
    private var claudeHasBeenTouched: Bool {
        switch claude {
        case .installing, .ready, .failed, .updateWaiting: true
        default: false
        }
    }

    @ObservationIgnored private let locations: StoreLocations
    @ObservationIgnored private let hosts: HostSet
    @ObservationIgnored private var resolved: HostKeyCheck.Resolved?
    @ObservationIgnored private var fetched: HostKeyCheck.Fetched?
    @ObservationIgnored private var connection: ServerConnection?
    @ObservationIgnored private var recorded = false

    init(locations: StoreLocations, hosts: HostSet) {
        self.locations = locations
        self.hosts = hosts
    }

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canConnect: Bool { ServerHost.isValid(trimmedName) && !isWorking }
    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }
    var label: String { host?.label ?? ServerHost.label(for: trimmedName) }

    func connect() async {
        guard let made = try? ServerHost(sshName: trimmedName) else { return }
        if hosts.hosts.all.contains(where: { $0.sshName == made.sshName }) {
            phase = .failed(.installFailed("\(made.label) is already added."), at: .connect)
            return
        }
        host = made
        done = []
        phase = .working(.connect)
        let ssh = HostSet.ssh(for: made, locations: locations)
        do {
            let resolved = try await HostKeyCheck.resolve(ssh)
            self.resolved = resolved
            if try await HostKeyCheck.isKnown(resolved) {
                await proceed()
            } else {
                let fetched = try await HostKeyCheck.fetch(ssh)
                self.fetched = fetched
                phase = .trust(fingerprint: fetched.fingerprint)
            }
        } catch let problem as HostProblem {
            phase = .failed(problem, at: .connect)
        } catch {
            phase = .failed(.installFailed("\(error)"), at: .connect)
        }
    }

    func trust() async {
        guard let fetched, let resolved else { return }
        do {
            try await HostKeyCheck.trust(fetched, into: resolved)
            self.fetched = nil
            host?.trustedFingerprint = fetched.fingerprint
            await proceed()
        } catch {
            phase = .failed(.installFailed("\(error)"), at: .connect)
        }
    }

    private func proceed() async {
        guard let host else { return }
        let connection = hosts.newConnection(for: host)
        self.connection = connection
        await connection.setOnState { [weak self] state in
            await self?.follow(state)
        }
        await connection.setOnClaude { [weak self] next in
            await self?.claudeMoved(next)
        }
        await connection.connect()
        guard case .connected = await connection.state else { return }
        system = await connection.facts.map { "\($0.system == "Linux" ? "Linux" : $0.system) · \($0.architecture.display)" }
        phase = .working(.findRuntimes)
        await findRuntimes()
    }

    func findRuntimes() async {
        guard let connection else { return }
        let listed = (try? await connection.client.call(DaemonAPI.Method.runtimesList,
                                                        returning: [RuntimeStatus].self)) ?? []
        let available = listed.filter { $0.availability.isAvailable }.map(\.runtime.name)
        done = [.connect, .checkSystem, .setUp, .installClaude, .findRuntimes]
        phase = .ready(runtimes: available)
        record()
    }

    private func claudeMoved(_ next: ServerConnection.Claude) {
        claude = next
    }

    /// Try Claude's install again from the sheet.
    func installClaude() async {
        await connection?.installClaude()
    }

    private func follow(_ state: ServerConnection.State) {
        switch state {
        case .connecting(let step):
            if case .working(let previous) = phase, previous != step, !done.contains(previous) { done.append(previous) }
            phase = .working(step)
        case .failed(let problem):
            let at: ServerConnection.Step
            if case .working(let step) = phase { at = step } else { at = .connect }
            phase = .failed(problem, at: at)
        default:
            break
        }
    }

    /// Ready, with or without runtimes: the host is kept, and the window keeps it
    /// connected from here on.
    private func record() {
        guard !recorded, var host, let connection else { return }
        recorded = true
        Task {
            host.facts = await connection.facts
            self.host = host
            self.hosts.add(host, connection: connection)
        }
    }

    func tryAgain() {
        phase = .name
        done = []
    }

    /// Leave nothing behind: no temporary key file, no connection. Anything set up on
    /// the server by a first install that failed has already been removed.
    func cancel() async {
        if let fetched { HostKeyCheck.discard(fetched) }
        fetched = nil
        if !recorded { await connection?.disconnect() }
    }
}
