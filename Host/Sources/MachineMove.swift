import AgentsKitCore
import AppKit
import Foundation
import Observation
import SwiftUI

/// What `agents-control handover status --json` says of a copy (058, research R16), read
/// here without linking the control plane's own types.
struct HandoverStatus: Codable, Equatable {
    var phase: String
    var controlKey: Data
    var hasRecords: Bool
    var endpoints: [ControlEndpoint]
    var epoch: Int?
    var members: [Member]
    var forwardingUntil: Date?

    struct Member: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var kind: String
        var knownEpoch: Int?
        var version: String?
        var online: Bool?
        var lastSeen: Date?

        func knows(_ epoch: Int?) -> Bool {
            guard let epoch else { return true }
            return (knownEpoch ?? 0) >= epoch
        }
    }

    /// Members that haven't heard of the list of `epoch` yet.
    var stillToHear: [Member] { members.filter { !$0.knows(epoch) } }
}

/// `agents-control handover …` with this Mac's key on a descriptor, and its home and port,
/// so `self` is this Mac's own copy even before it holds any records (T127).
@MainActor
enum HandoverTool {
    static func run(_ arguments: [String], model: HostModel) async -> ControlTool.Result {
        await ControlTool.run(["handover"] + arguments + ["--home", model.paths.controlHome.path, "--port", String(model.paths.port)],
                              paths: model.paths, settings: model.settings)
    }

    /// Whether this Mac's store is a bucket another copy can share: then a move copies
    /// nothing (R16 3, T128).
    static func sharesBucket(_ model: HostModel) -> Bool { model.settings.store == .bucket }

    /// Whether the copy at `place` reads the same store as `self`: a mark left here is
    /// found there.
    static func shares(_ place: String, model: HostModel) async -> ControlTool.Result {
        await run(["shares", "--at", "self", "--with", place], model: model)
    }

    static func status(_ arguments: [String], model: HostModel) async -> HandoverStatus? {
        let read = await run(["status"] + arguments + ["--json"], model: model)
        guard read.ok else { return nil }
        return try? JSONDecoder().decode(HandoverStatus.self, from: Data(read.output.utf8))
    }
}

/// Move to Another Machine… (058, T126, frames P–S): this Mac's control plane handed over
/// to a copy elsewhere, with every window, phone and server following without pairing
/// again. Each step is one `agents-control handover` run with the key on a descriptor.
@MainActor
@Observable
final class MachineMove {
    enum Step: Equatable { case key, check, told, moving }

    enum Tick: Equatable {
        case waiting
        case yes
        case no(String)
    }

    enum Stage: Equatable { case todo, doing, done, failed }

    let model: HostModel
    var step: Step = .key
    var address = ""
    var answers = Tick.waiting
    var trusted = Tick.waiting
    var holdsKey = Tick.waiting
    var empty = Tick.waiting
    private(set) var checking = false
    /// This Mac's copy, while everyone is being told.
    private(set) var status: HandoverStatus?
    /// R16 step 4 to 5, in frame S's order.
    private(set) var stages: [Stage] = Array(repeating: .todo, count: 5)
    private(set) var copied: String?
    private(set) var taken = false
    private(set) var finished = false
    var problem: String?
    private var watching: Task<Void, Never>?

    init(model: HostModel) { self.model = model }

    var checked: Bool { [answers, trusted, holdsKey, empty].allSatisfy { $0 == .yes } }
    /// Both copies read one bucket: nothing is copied, the other one already serves.
    var shared: Bool { HandoverTool.sharesBucket(model) }

    private func handover(_ arguments: [String]) async -> ControlTool.Result {
        await HandoverTool.run(arguments, model: model)
    }

    private var place: String { address.trimmingCharacters(in: .whitespacesAndNewlines) }

    // MARK: P · the key

    /// The control plane's key, as one file, for the person to copy to the other machine.
    func saveKey() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "control-key"
        panel.message = "Save the control plane's key, then copy it to the other machine as deploy/secrets/control-key."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        problem = nil
        do {
            try HostSecrets.saveControlKey(model.paths, to: url)
        } catch {
            // Said, so a missing or empty key is never copied to the other machine (#212).
            problem = WriteFailure(error, keeping: "the control plane's key")?.message ?? "The key could not be saved: \(error)"
        }
    }

    // MARK: Q · the check

    func check() async {
        guard !place.isEmpty else { return }
        checking = true
        defer { checking = false }
        answers = .waiting; trusted = .waiting; holdsKey = .waiting; empty = .waiting
        let result = await handover(["status", "--at", place, "--json"])
        if result.ok, let status = try? JSONDecoder().decode(HandoverStatus.self, from: Data(result.output.utf8)) {
            answers = .yes; trusted = .yes; holdsKey = .yes
            if shared {
                let same = status.phase == "serving" ? await HandoverTool.shares(place, model: model) : nil
                empty = same?.ok == true ? .yes
                    : .no("It keeps a store of its own. Start it with AGENTS_STORE set to this bucket, without AGENTS_CONTROL_RECEIVE.")
                return
            }
            empty = status.phase == "receiving" && !status.hasRecords ? .yes
                : .no("It already holds a control plane. Empty its store and start it with AGENTS_CONTROL_RECEIVE=1.")
            return
        }
        let said = result.problem
        if said.contains("CERTIFICATE") || said.contains("certificate") || said.contains("handshake") {
            answers = .yes
            trusted = .no("Windows and phones would refuse it. Give the machine a domain name and a certificate from Let's Encrypt; Caddy does this.")
        } else if said.contains("wrongControlPlane") || said.contains("wrong-control-plane") || said.contains("badProof") {
            answers = .yes; trusted = .yes
            holdsKey = .no("Copy the key you saved to deploy/secrets/control-key there, empty its store, and start it again.")
        } else {
            answers = .no("Nothing answers at that address. Check it's started, and that the name points at the machine.")
        }
    }

    // MARK: R · tell everyone

    func tellEveryone() async {
        problem = nil
        let told = await handover(["announce", "--at", "self", "--endpoint", place])
        guard told.ok else { problem = told.problem; return }
        step = .told
        watch()
    }

    /// Who has heard, read from this Mac's copy every two seconds while R is shown.
    private func watch() {
        watching?.cancel()
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await self?.readStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func readStatus() async {
        let read = await handover(["status", "--at", "self", "--json"])
        if read.ok, let status = try? JSONDecoder().decode(HandoverStatus.self, from: Data(read.output.utf8)) {
            self.status = status
        }
    }

    func withdraw() async {
        watching?.cancel()
        let back = await handover(["withdraw", "--at", "self"])
        if !back.ok { problem = back.problem }
        status = nil
        step = .check
    }

    // MARK: S · moving

    func moveNow() async {
        watching?.cancel()
        problem = nil
        step = .moving
        stages = Array(repeating: .todo, count: 5)

        stages[0] = .doing
        let frozen = await handover(["freeze", "--at", "self"])
        guard frozen.ok else { return await stop(at: 0, frozen.problem) }
        stages[0] = .done

        if shared {
            // One bucket (R16 3): the other copy already serves these records.
            copied = "Nothing to copy: both read the same bucket"
            stages[1] = .done
            taken = true
            stages[2] = .done
        } else {
            stages[1] = .doing
            let copy = await handover(["copy", "--from", "self", "--to", place])
            guard copy.ok else {
                return await stop(at: 1, copy.problem + " Empty the other machine's store and start it again with AGENTS_CONTROL_RECEIVE=1.")
            }
            copied = copy.output.trimmingCharacters(in: .whitespacesAndNewlines)
            stages[1] = .done

            stages[2] = .doing
            let take = await handover(["take", "--at", place])
            guard take.ok else { return await stop(at: 2, take.problem) }
            taken = true
            stages[2] = .done
        }

        // From here there is no going back from the sheet: the other machine serves.
        stages[3] = .doing
        let forward = await handover(["forward", "--at", "self", "--endpoint", place, "--json"])
        let until = (try? JSONDecoder().decode(HandoverStatus.self, from: Data(forward.output.utf8)))?.forwardingUntil
            ?? Date().addingTimeInterval(30 * 24 * 3600)
        if !forward.ok { problem = forward.problem }
        // This Mac's host follows by itself: forwarding closes it, and it dials the new
        // place it is told. Seen arriving there.
        for _ in 0..<60 {
            let there = await handover(["status", "--at", place, "--json"])
            if there.ok, let status = try? JSONDecoder().decode(HandoverStatus.self, from: Data(there.output.utf8)),
               status.members.contains(where: { $0.id == HostID.mac.rawValue && $0.online == true }) { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        stages[3] = .done
        stages[4] = forward.ok ? .done : .failed
        model.moved(to: place, forwardingUntil: forward.ok ? until : nil)
        finished = true
    }

    /// A step failed before the other machine took over: everything here goes back.
    private func stop(at stage: Int, _ why: String) async {
        stages[stage] = .failed
        _ = await handover(["unfreeze", "--at", "self"])
        problem = why
        step = .told
        watch()
    }

    /// Cancel before the other machine takes over: nothing changes for anyone.
    func cancel() async {
        watching?.cancel()
        guard !taken else { return }
        if step == .told || step == .moving {
            _ = await handover(["unfreeze", "--at", "self"])
            _ = await handover(["withdraw", "--at", "self"])
        }
    }
}

/// Frames P–S.
struct MachineMoveSheet: View {
    @Environment(HostModel.self) private var host
    @Environment(\.dismiss) private var dismiss
    @State private var move: MachineMove?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let move {
                content(move)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear { if move == nil { move = MachineMove(model: host) } }
        .onChange(of: move?.finished) { if move?.finished == true { dismiss() } }
    }

    @ViewBuilder
    private func content(_ move: MachineMove) -> some View {
        @Bindable var move = move
        switch move.step {
        case .key:
            Text("Move the control plane to another machine").font(.title3.weight(.semibold))
            Text("Your windows, phones and servers stay paired, and this Mac stays a host. Agents keep working while it moves.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Self.stepTitle("1 · Give the other machine this control plane's key")
            Self.numbered(1) {
                Text("Save the key, and copy it to the other machine as \(Text("deploy/secrets/control-key").font(.system(.body, design: .monospaced))).")
                Text("Anyone who has it can pose as your control plane. Delete your copy once it's there.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Save Key…") { move.saveKey() }.padding(.top, 2)
            }
            Self.numbered(2) {
                if move.shared {
                    Text("Start the control plane there on this Mac's bucket, with the bucket's keys in its deploy/.env:")
                    Self.command(Self.bucketCommand(host))
                } else {
                    Text("Start the control plane there, empty, waiting for this one:")
                    Self.command("AGENTS_CONTROL_RECEIVE=1 docker compose \\\n  -f deploy/compose.public.yaml up -d")
                }
                Text("See Run the control plane in the cloud.").font(.callout).foregroundStyle(.secondary)
            }
            Self.buttons {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Continue") { move.step = .check }.keyboardShortcut(.defaultAction)
            }

        case .check:
            Text("Move the control plane to another machine").font(.title3.weight(.semibold))
            Self.stepTitle("2 · Where is it?")
            HStack {
                TextField("https://agents.example.com", text: $move.address)
                    .textFieldStyle(.roundedBorder).font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Address")
                    .onSubmit { Task { await move.check() } }
                Button("Check") { Task { await move.check() } }.disabled(move.address.isEmpty || move.checking)
            }
            Self.tick(move.answers, "It answers")
            Self.tick(move.trusted, "Its certificate is publicly trusted", note: "So no pin is needed, and it renews itself.")
            Self.tick(move.holdsKey, "It holds this control plane's key")
            Self.tick(move.empty, move.shared ? "It reads this Mac's bucket" : "It's empty, and waiting for this one")
            Self.problemLine(move.problem)
            Self.buttons {
                Button("Back") { move.step = .key }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Tell Everyone") { Task { await move.tellEveryone() } }
                    .keyboardShortcut(.defaultAction).disabled(!move.checked)
            }

        case .told:
            Text("Move the control plane to another machine").font(.title3.weight(.semibold))
            Self.stepTitle("3 · Tell everyone where it's going")
            Text("Everything that's paired now knows \(Text(move.address).font(.system(.body, design: .monospaced))) as well as this Mac.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Self.whoKnows(move.status)
            if let status = move.status {
                let knowing = status.members.count - status.stillToHear.count
                Text("\(knowing) of \(status.members.count) know. You can move now, or wait for the rest.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Self.problemLine(move.problem)
            Self.buttons {
                Button("Withdraw") { Task { await move.withdraw() } }
                Spacer()
                Button("Cancel") { Task { await move.cancel(); dismiss() } }
                Button("Move Now") { Task { await move.moveNow() } }.keyboardShortcut(.defaultAction)
            }

        case .moving:
            Text("Moving to \(URL(string: move.address)?.host ?? move.address)…").font(.title3.weight(.semibold))
            Self.stage(move.stages[0], "Holding records still", note: "Pairing and changes wait. Agents keep working.")
            Self.stage(move.stages[1], move.copied ?? "Copying records")
            Self.stage(move.stages[2], "\(URL(string: move.address)?.host ?? "It") takes over")
            Self.stage(move.stages[3], "This Mac's host and relay go there")
            Self.stage(move.stages[4], "This Mac sends anyone still coming here on to it")
            Self.problemLine(move.problem)
            Self.buttons {
                Spacer()
                if move.stages.contains(.failed) {
                    Button("Close") { dismiss() }
                } else {
                    Button("Cancel") { Task { await move.cancel(); dismiss() } }.disabled(move.taken)
                }
            }
        }
    }

    // MARK: Pieces

    static func command(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
    }

    /// compose.public.yaml on the bucket this Mac's copy uses (T128). The keys are not in
    /// it: they go in the machine's deploy/.env, never on a command line.
    static func bucketCommand(_ host: HostModel) -> String {
        let address = StoreAddress(.bucket, bucket: host.settings.bucket, paths: host.paths)
        let lines = ["AGENTS_STORE=\(address.url)"] + address.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return (lines + ["docker compose -f deploy/compose.public.yaml up -d"]).joined(separator: " \\\n  ")
    }

    static func stepTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    static func numbered(_ n: Int, @ViewBuilder _ content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor.opacity(0.15)))
            VStack(alignment: .leading, spacing: 4) { content() }.fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    static func tick(_ state: MachineMove.Tick, _ label: String, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            switch state {
            case .yes: Image(systemName: "checkmark").foregroundStyle(.green)
            case .no: Image(systemName: "xmark").foregroundStyle(.orange)
            case .waiting: Text("–").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if case .no(let why) = state {
                    Text(why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if state == .yes, let note {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    static func stage(_ state: MachineMove.Stage, _ label: String, note: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            switch state {
            case .done: Image(systemName: "checkmark").foregroundStyle(.green)
            case .doing: ProgressView().controlSize(.mini)
            case .failed: Image(systemName: "xmark").foregroundStyle(.orange)
            case .todo: Image(systemName: "circle").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    static func whoKnows(_ status: HandoverStatus?, learnsFrom: String = "this Mac") -> some View {
        if let status {
            VStack(spacing: 0) {
                ForEach(status.members) { member in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.id == HostID.mac.rawValue ? "This Mac" : member.name)
                            Text(Self.kind(member)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .leading, spacing: 2) {
                            if member.knows(status.epoch) {
                                Label("Knows", systemImage: "checkmark").foregroundStyle(.green)
                            } else if member.online == true {
                                Text("Can't follow").foregroundStyle(.orange)
                                Text("Update it first, or add it again afterwards").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Not yet").foregroundStyle(.secondary)
                                Text("Learns it from \(learnsFrom) when it next connects").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 250, alignment: .leading)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .accessibilityElement(children: .combine)
                    if member != status.members.last { Divider() }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)) }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    static func kind(_ member: HandoverStatus.Member) -> String {
        var parts: [String] = switch member.kind {
        case "mac": ["window"]
        case "iPhone": ["phone"]
        case "iPad": ["iPad"]
        case "relay": ["relay"]
        default: [member.id == HostID.mac.rawValue ? "host" : "server"]
        }
        if member.online != true, let seen = member.lastSeen {
            parts.append("last connected \(seen.formatted(.relative(presentation: .named)))")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    static func problemLine(_ problem: String?) -> some View {
        if let problem {
            Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func buttons(@ViewBuilder _ content: () -> some View) -> some View {
        HStack { content() }.padding(.top, 6)
    }
}
