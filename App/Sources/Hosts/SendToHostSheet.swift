import AgentsKitCore
import SwiftUI

/// Send to ‹host›… (#1123): a folder's or a worktree's folder on this Mac, sent to a host
/// and added there as a folder. `from` is the host the folder is on: this Mac's, whose
/// agentsd sends it itself, through the control plane (#4613), since the window is
/// sandboxed and reads no repository itself. The window only starts it and shows its row.
struct SendToHostRequest: Identifiable, Hashable {
    let folder: URL
    let from: MachineRef
    let host: MachineRef
    var id: String { "\(host.rawValue) \(folder.path)" }
}

extension AppModel {
    /// The hosts a folder on this Mac can be sent to: the servers that are reachable now.
    var sendTargets: [MachineRef] {
        hosts.servers.filter { $0 != .mac && !isOnThisMac($0) && !hostUnreachable($0) }
    }

    /// Whether a folder is this Mac's to send.
    func canSend(from host: MachineRef) -> Bool { host == .mac || isOnThisMac(host) }

    /// What the host has at `destination`.
    func receiveState(at destination: String, on host: MachineRef) async throws -> DaemonAPI.ReceiveState {
        try await client(for: host).call(DaemonAPI.Method.foldersReceiveState,
                                         DaemonAPI.ReceiveStateRequest(folder: destination),
                                         returning: DaemonAPI.ReceiveState.self)
    }

    /// What the sheet shows of the repository at `folder`, from this Mac's host.
    func sendFacts(_ folder: URL, on from: MachineRef) async throws -> DaemonAPI.SendFacts {
        try await client(for: from).call(DaemonAPI.Method.foldersSendFacts, DaemonAPI.SendFactsRequest(folder: folder),
                                         returning: DaemonAPI.SendFacts.self)
    }

    /// Starts sending what `request` names from the host `from` (this Mac's), which sends it
    /// itself, through the control plane (#4613): it answers once it has checked the folder
    /// there, and `send/changed` says how it goes. The window is free the whole time, and
    /// closing it stops nothing.
    func startSend(_ request: DaemonAPI.SendRequest, from: MachineRef) async throws {
        let summary = try await client(for: from).call(DaemonAPI.Method.foldersSend, request,
                                                        returning: DaemonAPI.SendSummary.self)
        // A small send can end before its answer comes.
        guard !sendsEnded.contains(summary.id) else { return }
        if let i = sends.firstIndex(where: { $0.id == summary.id }) {
            sends[i].request = request
            sends[i].from = from
        } else {
            sends.append(FolderSend(state: DaemonAPI.SendNotification(send: summary), request: request, from: from))
        }
    }

    /// Sends again what a send that stopped sent: the host checks the folder there again.
    func retrySend(_ send: FolderSend) async {
        guard let request = send.request else { return }
        sends.removeAll { $0.id == send.id }
        do {
            try await startSend(request, from: send.from)
        } catch {
            var stopped = send
            stopped.state.problem = describe(error)
            sends.append(stopped)
        }
    }

    /// Takes a send that stopped out of the Folders column.
    func putAwaySend(_ send: FolderSend) {
        sends.removeAll { $0.id == send.id }
    }

    /// A `send/changed`: the row goes a part further, shows why it stopped, or, once the
    /// folder is there, gives way to that folder.
    func sendChanged(_ change: DaemonAPI.SendNotification) {
        let i = sends.firstIndex { $0.id == change.send.id }
        if change.finished { sendsEnded.insert(change.send.id) }
        if change.finished, change.problem == nil {
            if let i { sends.remove(at: i) }
            if var summary = change.received {
                summary.host = MachineRef(rawValue: change.send.machine)
                upsert(summary)
            }
            return
        }
        if let i {
            sends[i].state = change
        } else {
            sends.append(FolderSend(state: change, request: nil, from: .mac))
        }
    }

    /// The sends this Mac's host is making, for a window that connects mid-send. Those
    /// that stopped stay, until they are sent again or put away.
    func refreshSends() async {
        guard let running = try? await client(for: .mac).call(DaemonAPI.Method.foldersSends,
                                                   returning: [DaemonAPI.SendNotification].self) else { return }
        let known = Dictionary(sends.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sends = sends.filter { $0.state.problem != nil }
            + running.map { FolderSend(state: $0, request: known[$0.send.id]?.request, from: known[$0.send.id]?.from ?? .mac) }
    }
}

/// A send in the Folders column (#4613): how it goes, and, when this window started it,
/// what Retry sends again and from which host.
struct FolderSend: Identifiable, Hashable {
    var state: DaemonAPI.SendNotification
    var request: DaemonAPI.SendRequest?
    var from: MachineRef
    var id: UUID { state.send.id }
}

/// A send under way (#4613), as a clone's row is (027): the folder, and how far it is on its
/// way to the machine. A send that stopped says why, with Retry, and × to put it away.
struct SendingRow: View {
    @Environment(AppModel.self) private var model
    let send: FolderSend

    private var name: String { send.state.send.folder.lastPathComponent }
    private var machine: String { send.state.send.machineName }

    private var line: String {
        let s = send.state
        guard s.total >= 1_000_000 else { return "Sending to \(machine)…" }
        return "Sending to \(machine): \(s.sent.formatted(.byteCount(style: .file))) of \(s.total.formatted(.byteCount(style: .file)))…"
    }

    var body: some View {
        if let problem = send.state.problem {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Text(problem)
                        .appText(.fine).tinted(.failure)
                        .lineLimit(3)
                        .help(problem)
                }
                Spacer(minLength: 4)
                if send.request != nil {
                    Button("Retry") { Task { await model.retrySend(send) } }
                        .buttonStyle(.link)
                        .appText(.fine)
                }
                Button { model.putAwaySend(send) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Put away")
                    .accessibilityLabel("Put away")
            }
        } else {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    Text(line)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                ProgressView().controlSize(.small)
            }
            .help("\(send.state.send.destination) on \(machine)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Sending \(name) to \(send.state.send.destination) on \(machine)")
        }
    }
}

extension View {
    /// The Send to ‹host›… sheet a folder's menu asks for in `requests`.
    func sendToHostSheet(_ requests: WindowRequests) -> some View {
        sheet(item: Binding(get: { requests.sendToHost }, set: { requests.sendToHost = $0 })) { request in
            SendToHostSheet(request: request).paperSheet()
        }
    }
}

/// A send that stops before it starts, in words.
struct SendFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// The sheet: the folder on the host, the branches to send, and whether the uncommitted
/// changes go too. Sending again brings the host's copy up to date with only what it lacks.
struct SendToHostSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SendToHostRequest

    @State private var facts: DaemonAPI.SendFacts?
    @State private var chosen: Set<String> = []
    @State private var includeChanges = true
    @State private var destination = ""
    @State private var state: DaemonAPI.ReceiveState?
    @State private var progress: String?
    @State private var problem: String?

    private var label: String { model.hosts.label(request.host) }
    private var name: String { request.folder.lastPathComponent }

    /// The branch the host checks out: this Mac's when it goes, or else the first chosen.
    private var checkout: String? {
        guard let facts else { return nil }
        if let current = facts.current, chosen.contains(current) { return current }
        return facts.branches.first(where: chosen.contains)
    }

    /// The uncommitted changes sit on the branch checked out here, so they go only with it.
    private var changesCanGo: Bool {
        guard let facts, let current = facts.current else { return false }
        return facts.hasChanges && chosen.contains(current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send \(name) to \(label)")
                .appText(.reading).fontWeight(.semibold)
            if let facts {
                form(facts)
            } else if problem == nil {
                ProgressView().controlSize(.small)
            }
            if let problem {
                Text(problem)
                    .appText(.fine).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress {
                Text(progress).appText(.fine).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.paper)
                    .keyboardShortcut(.cancelAction)
                    .disabled(progress != nil)
                Button("Send") { Task { await send() } }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
    }

    @ViewBuilder private func form(_ facts: DaemonAPI.SendFacts) -> some View {
        LabeledContent("Folder on \(label)") {
            TextField("~/\(name)", text: $destination)
                .textFieldStyle(.roundedBorder)
                .onSubmit { Task { await check() } }
        }
        Text(stateLine)
            .appText(.fine).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text("Branches").appText(.supporting).fontWeight(.semibold)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(facts.branches, id: \.self) { branch in
                    Toggle(isOn: Binding(get: { chosen.contains(branch) },
                                         set: { if $0 { chosen.insert(branch) } else { chosen.remove(branch) } })) {
                        Text(branch == facts.current ? "\(branch) (checked out)" : branch)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        Toggle("Include uncommitted changes", isOn: $includeChanges)
            .toggleStyle(.checkbox)
            .disabled(!changesCanGo)
        Text(changesLine(facts))
            .appText(.fine).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stateLine: String {
        guard let state else { return "Checking \(label)…" }
        if state.ownChanges {
            return "This folder has changes of its own on \(label). Commit or remove them there, then send again."
        }
        if state.repository {
            return "\(label) has a copy here. Sending again brings it up to date with only the commits it lacks. Its own commits stop the send."
        }
        if state.exists {
            return "This folder is on \(label) and is not a Git repository. It must be empty."
        }
        return "A new copy, with the same origin as here."
    }

    private func changesLine(_ facts: DaemonAPI.SendFacts) -> String {
        guard facts.hasChanges else { return "Nothing is uncommitted." }
        guard let current = facts.current, chosen.contains(current) else {
            return "The uncommitted changes go only with the branch checked out here."
        }
        return "Changed and new files go as a patch on \(current). Files that git ignores do not go."
    }

    private var canSend: Bool {
        progress == nil && checkout != nil && state != nil && state?.ownChanges != true
            && !destination.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func load() async {
        destination = "~/\(name)"
        do {
            let facts = try await model.sendFacts(request.folder, on: request.from)
            guard !facts.branches.isEmpty else {
                problem = "\(name) has no branch with a commit to send."
                return
            }
            chosen = [facts.current ?? facts.branches[0]]
            self.facts = facts
        } catch {
            problem = model.describe(error)
            return
        }
        await check()
    }

    private func check() async {
        state = nil
        problem = nil
        do {
            state = try await model.receiveState(at: destination, on: request.host)
        } catch {
            problem = model.describe(error)
        }
    }

    private func send() async {
        guard let facts, let checkout else { return }
        problem = nil
        progress = "Checking \(label)…"
        do {
            try await model.startSend(
                DaemonAPI.SendRequest(folder: request.folder, machine: request.host.rawValue, machineName: label,
                                      destination: destination, branches: facts.branches.filter(chosen.contains),
                                      checkout: checkout, includeChanges: includeChanges && changesCanGo, origin: facts.origin),
                from: request.from)
            dismiss()
        } catch {
            progress = nil
            problem = model.describe(error)
        }
    }
}
