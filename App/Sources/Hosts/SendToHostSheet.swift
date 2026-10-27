import AgentsKitCore
import SwiftUI

/// Send to ‹host›… (#1123): a folder's or a worktree's folder on this Mac, sent to a host
/// over the link the window already has to it, and added there as a folder. `from` is the
/// host the folder is on: this Mac's, whose agentsd makes the bundle and the patch, since
/// the window is sandboxed and reads no repository itself.
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

    /// Sends `branches` of the repository at `folder` on this Mac's host `from`, less what
    /// `host` already has, and the uncommitted changes when `includeChanges`, then has
    /// `host` make or bring up to date its copy at `destination`. Each part goes through
    /// the window, from one host's link to the other's. The folder it becomes is listed
    /// and returned.
    func sendRepository(_ folder: URL, from: MachineRef, to host: MachineRef, at destination: String, branches: [String],
                        checkout: String, includeChanges: Bool, origin: String?,
                        progress: @escaping @MainActor (String) -> Void) async throws -> DaemonAPI.FolderSummary {
        let label = hosts.label(host)
        let state = try await receiveState(at: destination, on: host)
        if state.ownChanges {
            throw SendFailure(message: "\(destination) has changes of its own on \(label). Commit or remove them there, then send again.")
        }
        progress("Making the bundle…")
        let mac = client(for: from), there = client(for: host)
        let pack = try await mac.callWhileAnswering(
            DaemonAPI.Method.foldersSendPack,
            DaemonAPI.SendPackRequest(folder: folder, branches: branches, leavingOut: state.repository ? state.heads : [],
                                      includeChanges: includeChanges),
            checkingEvery: .seconds(10)).decode(DaemonAPI.SendPack.self)
        let (bundle, patch) = try await relay(pack, from: mac, to: there, verb: "Sending", progress: progress)
        progress("Adding it on \(label)…")
        let answer = try await there.callWhileAnswering(
            DaemonAPI.Method.foldersReceive,
            DaemonAPI.ReceiveRequest(folder: destination, bundle: bundle, patch: patch, branches: pack.commits,
                                     checkout: checkout, origin: origin),
            checkingEvery: .seconds(10))
        var summary = try answer.decode(DaemonAPI.FolderSummary.self)
        summary.host = host
        upsert(summary)
        return summary
    }

    /// Carries the bundle and the patch a pack made from one host's link to the other's, in
    /// the parts `from` reads, and answers with the uploads they became on `to`.
    ///
    /// A part's base64 text goes on as it came, never decoded and encoded again, and the
    /// next part is read while this one is uploaded (#1530): the window holds about two
    /// parts of 1 MB, and a part on the link holds the host's other lines for a moment only.
    func relay(_ pack: DaemonAPI.SendPack, from: DaemonClient, to: DaemonClient, verb: String,
               progress: @escaping @MainActor (String) -> Void) async throws -> (bundle: UUID?, patch: UUID?) {
        let total = (pack.bundle?.size ?? 0) + (pack.patch?.size ?? 0)
        var sent = 0
        func read(_ file: DaemonAPI.SendFile, at offset: Int) async throws -> RelayPart {
            try RelayPart(try await from.call(DaemonAPI.Method.foldersSendRead,
                                              DaemonAPI.SendReadRequest(id: file.id, offset: offset)))
        }
        func carry(_ file: DaemonAPI.SendFile?) async throws -> UUID? {
            guard let file else { return nil }
            let id = UUID()
            var offset = 0
            var part = try await read(file, at: 0)
            while true {
                let next = offset + part.size, more = !part.end && part.size > 0
                async let ahead: RelayPart? = more ? try await read(file, at: next) : nil
                try await to.call(DaemonAPI.Method.foldersReceiveUpload,
                                  JSONValue.object(["upload": .string(id.uuidString), "offset": .int(offset), "data": part.data]))
                offset = next
                sent += part.size
                progress(total < 1_000_000 ? "\(verb)…"
                         : "\(verb) \(sent.formatted(.byteCount(style: .file))) of \(total.formatted(.byteCount(style: .file)))…")
                guard let following = try await ahead else { return id }
                part = following
            }
        }
        return (try await carry(pack.bundle), try await carry(pack.patch))
    }
}

/// One part of a send as `folders/sendRead` answered it: its data still the base64 text.
struct RelayPart: Sendable {
    let data: JSONValue
    let size: Int
    let end: Bool

    init(_ answer: JSONValue) throws {
        guard let text = answer["data"]?.stringValue, let end = answer["end"]?.boolValue else {
            throw SendFailure(message: "A part of the send came back in a shape this window cannot read.")
        }
        data = .string(text)
        size = Self.decodedSize(text)
        self.end = end
    }

    /// The bytes base64 `text` holds, without decoding it.
    static func decodedSize(_ text: String) -> Int {
        let utf8 = text.utf8
        let padding = utf8.reversed().prefix(2).prefix(while: { $0 == UInt8(ascii: "=") }).count
        return utf8.count / 4 * 3 - padding
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
            let summary = try await model.sendRepository(
                request.folder, from: request.from, to: request.host, at: destination,
                branches: facts.branches.filter(chosen.contains), checkout: checkout,
                includeChanges: includeChanges && changesCanGo, origin: facts.origin) { progress = $0 }
            dismiss()
            model.select(summary.key)
        } catch {
            progress = nil
            problem = model.describe(error)
        }
    }
}
