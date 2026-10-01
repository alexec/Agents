import AgentsKit
import AgentsKitCore
import Foundation
import SwiftUI

/// Moving the earlier app's set-up across, once, from Agents Host (058, US7, T084–T086):
/// frame L's strip, and frame I's sheet behind it.
///
/// Nothing in the old root moves. It becomes this Mac's host where it is (T083); its paired
/// devices become device clients with their own keys; the servers its window reached by
/// ssh join with the one-line command, run over the person's own ssh as before, or are
/// listed with it; and every device that connects the old way is told where the control
/// plane is now. Until the control plane has the devices, a failure leaves the old way as
/// it was: the earlier app starts its daemon again on the same root.
@MainActor
@Observable
final class HostMove {
    enum Phase: Equatable {
        case offer
        case moving(String)
        case done
        case failed(String)
    }

    struct Server: Identifiable, Equatable {
        var id: String { label }
        let label: String
        /// Joined over ssh, or the line to run there.
        var joined: Bool
        var command: String?
        var why: String?
    }

    private(set) var phase: Phase = .offer
    private(set) var servers: [Server] = []
    let summary: ControlMove.Summary
    private let paths: HostPaths

    init(paths: HostPaths) {
        self.paths = paths
        summary = ControlMove.summary(of: paths.hostLocations)
    }

    /// Whether frame L offers the move: an earlier set-up here, not moved yet.
    static func offered(_ paths: HostPaths) -> Bool {
        let locations = paths.hostLocations
        guard !FileManager.default.fileExists(atPath: locations.controlMoved.path) else { return false }
        let summary = ControlMove.summary(of: locations)
        return !summary.devices.isEmpty || !summary.servers.isEmpty
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    func run(model: HostModel) async {
        let locations = paths.hostLocations
        do {
            phase = .moving("Letting the earlier app’s agents go…")
            try await letTheOldDaemonGo()

            phase = .moving("Starting the control plane and this Mac’s host…")
            model.problem = nil
            await model.runHere()
            if let problem = model.problem { throw Failure(problem) }
            guard let code = model.lastHostCode, let url = code.url else {
                throw Failure("The control plane gave no address to tell your devices.")
            }

            phase = .moving("Moving your devices…")
            let moved = await ControlTool.run(["move", "--from", locations.root.path, "--home", paths.controlHome.path],
                                              paths: paths, settings: model.settings, key: false)
            guard moved.ok else { throw Failure(moved.output.trimmingCharacters(in: .whitespacesAndNewlines)) }

            // From here the devices are the control plane's: tell each one that connects
            // the old way where to go (T085).
            let notice = DaemonAPI.ControlMoved(url: url, pin: code.pin, controlKey: code.controlKey, name: code.name)
            try JSONEncoder().encode(notice).write(to: locations.controlMoved, options: .atomic)

            let listed = moved.output.split(separator: "\n").compactMap { line -> (String, String)? in
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                return parts.count == 3 && parts[0] == "server" ? (String(parts[1]), String(parts[2])) : nil
            }
            for (sshName, label) in listed {
                phase = .moving("Adding \(label) as a host…")
                servers.append(await join(sshName: sshName, label: label, model: model))
            }
            try? ControlMove.retireServers(of: locations)
            await model.refresh()
            phase = .done
        } catch {
            phase = .failed("\(error)")
        }
    }

    /// The earlier app's daemon, if it still has this root, is asked to go; agents are
    /// left running. One mid-turn makes it refuse, and nothing has changed yet.
    private func letTheOldDaemonGo() async throws {
        let locations = paths.hostLocations
        guard FileManager.default.fileExists(atPath: locations.socket.path) else { return }
        if await LocalServices(paths: paths).running(.daemon) != nil { return }
        let client = DaemonClient(link: LookingLink(locations: locations))
        guard (try? await client.connect(startIfNeeded: false, timeout: .seconds(2))) != nil else { return }
        do {
            _ = try await client.call(DaemonAPI.Method.daemonQuit, DaemonAPI.QuitRequest(stopAgents: false))
        } catch let error as JSONRPCError {
            throw Failure("an agent is working. Let its turn finish, then try again. (\(error.message))")
        }
        await client.disconnect()
        for _ in 0..<60 {
            if let lock = DaemonLock(at: locations.lock) { lock.release(); return }
            try? await Task.sleep(for: .milliseconds(250))
        }
        throw Failure("the earlier Agents app’s daemon didn’t stop. Quit Agents, then try again.")
    }

    /// A server the old window reached by ssh: a host code and its command, run there over
    /// the person's own ssh, as the window did. The key never leaves this Mac.
    private func join(sshName: String, label: String, model: HostModel) async -> Server {
        let made = await ControlTool.run(["code", "--host", "--command", "--home", paths.controlHome.path],
                                         paths: paths, settings: model.settings)
        guard made.ok, let line = made.output.split(separator: "\n").first(where: { $0.hasPrefix("command\t") }) else {
            return Server(label: label, joined: false, command: nil, why: "no host code: \(made.output)")
        }
        let command = String(line.dropFirst("command\t".count))
        let ssh = SSHCommand(name: sshName, controlPath: nil)
        do {
            let output = try await ssh.run(ssh.runArguments(command))
            if output.status == 0 { return Server(label: label, joined: true, command: nil, why: nil) }
            let why = output.stderr.split(separator: "\n").last.map(String.init) ?? "ssh said \(output.status)"
            return Server(label: label, joined: false, command: command, why: why)
        } catch {
            return Server(label: label, joined: false, command: command, why: "\(error)")
        }
    }
}

/// Frame L's strip: the move offered, never the move itself.
struct MoveStrip: View {
    @Binding var moving: Bool

    var body: some View {
        HStack {
            Text("You have agents from the earlier Agents app on this Mac.")
            Spacer()
            Button("Move Across…") { moving = true }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Frame I's content, in Agents Host (T086).
struct MoveSheet: View {
    @Environment(HostModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var move = HostMove(paths: HostPaths.current)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Move to a control plane on this Mac").font(.headline)
            switch move.phase {
            case .offer:
                Text("This sets up a control plane on this Mac and keeps everything you have:")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    kept(move.summary.agents == 1
                         ? "Your agent and its conversation stay on this Mac, as this Mac’s host"
                         : "All \(move.summary.agents) agents and their conversations stay on this Mac, as this Mac’s host")
                    if !move.summary.devices.isEmpty {
                        kept("\(ListFormatter.localizedString(byJoining: move.summary.devices)) \(move.summary.devices.count == 1 ? "keeps" : "keep") working, without pairing again")
                    }
                    if !move.summary.servers.isEmpty {
                        kept("\(ListFormatter.localizedString(byJoining: move.summary.servers)) \(move.summary.servers.count == 1 ? "is added as a host" : "are added as hosts"), over your ssh as now")
                    }
                    kept("Work on this Mac carries on after a restart, without opening Agents")
                }
                Text("Your iPhone and iPad will be able to do what they can today, and now on your servers too. You can let one do everything in Settings ▸ Control plane ▸ Clients.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .moving(let step):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(step)
                }
            case .done:
                Text("Moved. Your devices are told where the control plane is the next time they connect.")
                    .foregroundStyle(.green)
                ForEach(move.servers) { server in
                    if server.joined {
                        kept("\(server.label) joined as a host")
                    } else {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(server.label) couldn’t be reached over ssh\(server.why.map { ": \($0)" } ?? ""). Run this there to add it:")
                                .fixedSize(horizontal: false, vertical: true)
                            if let command = server.command {
                                Text(command).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    .padding(8).background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            case .failed(let why):
                Text("Nothing has changed: \(why)").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                switch move.phase {
                case .offer, .failed:
                    Button("Not Now") { dismiss() }
                    Button(move.phase == .offer ? "Move Across" : "Try Again") {
                        Task { await move.run(model: model) }
                    }
                    .keyboardShortcut(.defaultAction)
                case .moving:
                    EmptyView()
                case .done:
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(isMoving)
    }

    private var isMoving: Bool { if case .moving = move.phase { true } else { false } }

    private func kept(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "checkmark").foregroundStyle(.green)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}
