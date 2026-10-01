import AgentsKitCore
import Foundation
import Observation
import SwiftUI

/// Run It Here Again… (058, T127, frames V–X): the control plane brought back from the
/// machine it was moved to, with every window, phone and server following without pairing
/// again. The move the other way round: this Mac's copy receives, the other one forwards.
@MainActor
@Observable
final class MachineReturn {
    enum Step: Equatable { case check, told, moving }

    let model: HostModel
    var step: Step = .check
    var reachable = MachineMove.Tick.waiting
    var ready = MachineMove.Tick.waiting
    private(set) var checking = false
    /// Where the store from before the move was put aside.
    private(set) var aside: String?
    /// The other machine's copy, while everyone is being told: members report there.
    private(set) var status: HandoverStatus?
    private(set) var stages: [MachineMove.Stage] = Array(repeating: .todo, count: 5)
    private(set) var copied: String?
    private(set) var taken = false
    private(set) var finished = false
    var problem: String?
    private var watching: Task<Void, Never>?

    init(model: HostModel) { self.model = model }

    /// Where the control plane runs now.
    var place: String { model.settings.movedTo ?? "" }
    var placeName: String { URL(string: place)?.host ?? place }
    var checked: Bool { reachable == .yes && ready == .yes }

    private func handover(_ arguments: [String]) async -> ControlTool.Result {
        await HandoverTool.run(arguments, model: model)
    }

    // MARK: V · check both ends

    func check() async {
        checking = true
        defer { checking = false }
        reachable = .waiting
        ready = .waiting
        let there = await handover(["status", "--at", place, "--json"])
        if there.ok, let status = try? JSONDecoder().decode(HandoverStatus.self, from: Data(there.output.utf8)),
           status.phase == "serving" {
            reachable = .yes
        } else if there.problem.contains("wrongControlPlane") || there.problem.contains("badProof") {
            reachable = .no("It holds another control plane's key, so this Mac can't take it back from there.")
            return
        } else {
            reachable = .no("The control plane is unreachable, so this Mac can't take it back from there. Check the machine is running, then Check Again.")
            return
        }
        // This Mac's copy: forwarding stops, the store from before is kept aside, and it
        // starts empty to receive.
        if model.settings.receiving != true { aside = await model.prepareReturn() }
        for _ in 0..<40 {
            if let mine = await HandoverTool.status(["--at", "self"], model: model) {
                ready = mine.phase == "receiving" && !mine.hasRecords ? .yes
                    : .no("This Mac's copy already holds records. Keep its store aside and start it again.")
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        ready = .no("This Mac's copy didn't start. Its log is at \(model.paths.controlLog.path).")
    }

    // MARK: W · tell everyone

    func tellEveryone() async {
        problem = nil
        let told = await handover(["announce", "--at", place, "--endpoint", "self"])
        guard told.ok else { problem = told.problem; return }
        step = .told
        watch()
    }

    private func watch() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if let read = await HandoverTool.status(["--at", self.place], model: self.model) { self.status = read }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func withdraw() async {
        watching?.cancel()
        let back = await handover(["withdraw", "--at", place])
        if !back.ok { problem = back.problem }
        status = nil
        step = .check
    }

    // MARK: X · moving back

    func moveNow() async {
        watching?.cancel()
        problem = nil
        step = .moving
        stages = Array(repeating: .todo, count: 5)

        stages[0] = .doing
        let frozen = await handover(["freeze", "--at", place])
        guard frozen.ok else { return await stop(at: 0, frozen.problem) }
        stages[0] = .done

        stages[1] = .doing
        let copy = await handover(["copy", "--from", place, "--to", "self"])
        guard copy.ok else { return await stop(at: 1, copy.problem) }
        copied = copy.output.trimmingCharacters(in: .whitespacesAndNewlines)
        stages[1] = .done

        stages[2] = .doing
        let take = await handover(["take", "--at", "self"])
        guard take.ok else { return await stop(at: 2, take.problem) }
        taken = true
        stages[2] = .done

        // From here this Mac serves; the other machine tells whoever still goes there.
        stages[3] = .doing
        let forward = await handover(["forward", "--at", place, "--endpoint", "self", "--json"])
        let until = (try? JSONDecoder().decode(HandoverStatus.self, from: Data(forward.output.utf8)))?.forwardingUntil
            ?? Date().addingTimeInterval(30 * 24 * 3600)
        if !forward.ok { problem = forward.problem }
        // This Mac's own host comes back by itself, told by the forwarding copy.
        for _ in 0..<60 {
            if let mine = await HandoverTool.status(["--at", "self"], model: model),
               mine.members.contains(where: { $0.id == HostID.mac.rawValue && $0.online == true }) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        stages[3] = .done
        stages[4] = forward.ok ? .done : .failed
        model.returned(from: place, forwardingUntil: forward.ok ? until : nil)
        finished = true
    }

    /// A step failed before this Mac took over: the other machine serves again, as before.
    private func stop(at stage: Int, _ why: String) async {
        stages[stage] = .failed
        _ = await handover(["unfreeze", "--at", place])
        problem = why
        step = .told
        watch()
    }

    /// Cancel before this Mac takes over: nothing changes for anyone, and this Mac's empty
    /// copy stops again.
    func cancel() async {
        watching?.cancel()
        guard !taken else { return }
        if step == .told || step == .moving {
            _ = await handover(["unfreeze", "--at", place])
            _ = await handover(["withdraw", "--at", place])
        }
        if model.settings.receiving == true { await model.undoReturn() }
    }
}

/// Frames V–X.
struct MachineReturnSheet: View {
    @Environment(HostModel.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var back: MachineReturn?

    private typealias Pieces = MachineMoveSheet

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let back { content(back) }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { if back == nil { back = MachineReturn(model: host) } }
        .task { if back?.reachable == .waiting { await back?.check() } }
        .onChange(of: back?.finished) { if back?.finished == true { dismiss() } }
    }

    @ViewBuilder
    private func content(_ back: MachineReturn) -> some View {
        switch back.step {
        case .check:
            Text("Bring the control plane back to this Mac").font(.title3.weight(.semibold))
            Text("Your windows, phones and servers stay paired. Agents keep working while it moves.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Pieces.stepTitle("1 · Check both ends")
            Pieces.tick(back.reachable, "\(back.placeName) answers, and holds this control plane's key")
            Pieces.tick(back.ready, "This Mac's copy is ready, empty, waiting for it",
                        note: back.aside.map { "The store from before the move is kept in Agents Control as \($0)." })
            HStack(alignment: .top, spacing: 10) {
                Text("!").font(.body.weight(.semibold)).foregroundStyle(.secondary).frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Away from home, iPhone and iPad can't reach this Mac directly")
                    Text("\(back.placeName) had a public address; this Mac doesn't. On your network they connect as before. Away, they go through your iCloud when Relay for my devices is on, and not at all while it's off.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Pieces.problemLine(back.problem)
            Pieces.buttons {
                if !back.checked {
                    Button("Check Again") { Task { await back.check() } }.disabled(back.checking)
                }
                Spacer()
                Button("Cancel") { Task { await back.cancel(); dismiss() } }
                Button("Tell Everyone") { Task { await back.tellEveryone() } }
                    .keyboardShortcut(.defaultAction).disabled(!back.checked)
            }

        case .told:
            Text("Bring the control plane back to this Mac").font(.title3.weight(.semibold))
            Pieces.stepTitle("2 · Tell everyone where it's going")
            Text("Everything that's paired now knows \(Text(URL(string: host.controlURL)?.host ?? "this Mac").font(.system(.body, design: .monospaced))) as well as \(back.placeName).")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Pieces.whoKnows(back.status, learnsFrom: back.placeName)
            if let status = back.status {
                let knowing = status.members.count - status.stillToHear.count
                Text("\(knowing) of \(status.members.count) know. You can move now, or wait for the rest.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Pieces.problemLine(back.problem)
            Pieces.buttons {
                Button("Withdraw") { Task { await back.withdraw() } }
                Spacer()
                Button("Cancel") { Task { await back.cancel(); dismiss() } }
                Button("Move Now") { Task { await back.moveNow() } }.keyboardShortcut(.defaultAction)
            }

        case .moving:
            Text("Moving back to this Mac…").font(.title3.weight(.semibold))
            Pieces.stage(back.stages[0], "Holding records still at \(back.placeName)",
                         note: "Pairing and changes wait. Agents keep working.")
            Pieces.stage(back.stages[1], back.copied ?? "Copying records to this Mac")
            Pieces.stage(back.stages[2], "This Mac takes over")
            Pieces.stage(back.stages[3], "Hosts come back here")
            Pieces.stage(back.stages[4], "\(back.placeName) sends anyone still going there on to this Mac")
            Pieces.problemLine(back.problem)
            Pieces.buttons {
                Spacer()
                if back.stages.contains(.failed) {
                    Button("Close") { dismiss() }
                } else {
                    Button("Cancel") { Task { await back.cancel(); dismiss() } }.disabled(back.taken)
                }
            }
        }
    }
}
