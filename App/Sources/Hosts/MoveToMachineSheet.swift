import AgentsKitCore
import SwiftUI

/// Move to Machine… (#3790): a session goes on on another of the person's machines, as an
/// agent's move_session does (#3717). Its host stops the turn if one runs, sends the branch
/// with its uncommitted changes to the folder there, and that machine takes the session with
/// its id, labels and transcript; this host then lets it go. The host answers once it has
/// checked the move (#4641): the sheet closes, and the session's row says how it goes.
extension AppModel {
    /// The machines `agent` can move to: the others that are online now. Nil when its host
    /// cannot move a session, or is not answering.
    func moveTargets(for agent: Agent) -> [MachineRef]? {
        guard agent.state != .archived, !hostUnreachable(agent.host), host(agent.host, has: Capability.sessionsMove1) else { return nil }
        let here: Set<MachineRef> = agent.host == .mac ? [.mac, thisMacHostID ?? .mac] : [agent.host]
        return hosts.servers.filter { !here.contains($0) && !hostUnreachable($0) }
    }

    /// Moves `agent` to `machine`, into `folder` there, or the folder of its project there
    /// when `folder` is empty. It answers once the host has checked the move, and
    /// `move/changed` says how it goes; the session stays here until that machine has it.
    func moveToMachine(_ agent: Agent, machine: MachineRef, folder: String) async throws -> DaemonAPI.MoveToMachineAnswer {
        let folder = folder.trimmingCharacters(in: .whitespaces)
        return try await client(for: agent.host).callWhileAnswering(
            DaemonAPI.Method.agentsMoveToMachine,
            DaemonAPI.MoveToMachineRequest(agentID: agent.id, machine: machine.rawValue, machineName: hosts.label(machine),
                                           folder: folder.isEmpty ? nil : folder),
            checkingEvery: .seconds(10)).decode(DaemonAPI.MoveToMachineAnswer.self)
    }

    /// A `move/changed`: the row's line goes a step further, says why it stopped, or, once
    /// the session is there, goes.
    func moveChanged(_ change: DaemonAPI.MoveNotification) {
        if change.finished, change.problem == nil {
            moves[change.agentID] = nil
        } else {
            moves[change.agentID] = change
        }
    }

    /// Takes a move that stopped off its session's row.
    func putAwayMove(_ agentID: UUID) {
        if moves[agentID]?.finished == true { moves[agentID] = nil }
    }

    /// The moves `host` is making, for a window that connects mid-move. Those that
    /// stopped stay until they are put away.
    func refreshMoves(on host: MachineRef) async {
        guard self.host(host, has: Capability.sessionsMoving1),
              let running = try? await client(for: host).call(DaemonAPI.Method.agentsMoves,
                                                               returning: [DaemonAPI.MoveNotification].self) else { return }
        for move in running { moves[move.agentID] = move }
    }
}

/// The sheet: the machine, and the folder there.
struct MoveToMachineSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let agent: Agent

    @State private var machine: MachineRef?
    @State private var folder = ""
    @State private var moving = false
    @State private var problem: String?

    private var targets: [MachineRef] { model.moveTargets(for: agent) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(MoveToMachineWords.title(agent.title))
                .appText(.reading).fontWeight(.semibold)
            if targets.isEmpty {
                Text(MoveToMachineWords.noTargets)
                    .appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Machine", selection: $machine) {
                    ForEach(targets, id: \.self) { host in
                        Text(model.hosts.label(host)).tag(Optional(host))
                    }
                }
                LabeledContent(MoveToMachineWords.folderLabel) {
                    TextField(MoveToMachineWords.folderPlaceholder, text: $folder)
                        .textFieldStyle(.roundedBorder)
                }
                Text(MoveToMachineWords.folderHelp)
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(MoveToMachineWords.whatGoes(stops: model.canStop(agent)))
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(problem)
                    .appText(.fine).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            } else if moving {
                Text(MoveToMachineWords.moving).appText(.fine).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.paper)
                    .keyboardShortcut(.cancelAction)
                    .disabled(moving)
                Button("Move") { Task { await move() } }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(moving || machine == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { machine = machine ?? targets.first }
    }

    private func move() async {
        guard let machine else { return }
        problem = nil
        moving = true
        do {
            _ = try await model.moveToMachine(agent, machine: machine, folder: folder)
            dismiss()
        } catch {
            moving = false
            problem = model.describe(error)
        }
    }
}
