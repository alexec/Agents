import AgentsKitCore
import SwiftUI

/// Bring back from ‹host›… (#1473), the reverse of Send to ‹host›… (#1123): a host's
/// branches come back into the repository at `folder` on this Mac, forward only. `from` is
/// this Mac's host, which brings them back itself, through the control plane (#4640), since
/// the window is sandboxed and reads no repository itself. The window only starts it and
/// shows its row.
struct BringBackFromHostRequest: Identifiable, Hashable {
    let folder: URL
    let from: MachineRef
    let host: MachineRef
    var id: String { "\(host.rawValue) \(folder.path)" }
}

extension AppModel {
    /// Starts bringing back what `request` names into this Mac's host `from`, which brings
    /// it back itself, through the control plane (#4640): it answers once it has checked the
    /// machine, and `bringBack/changed` says how it goes. The window is free the whole time,
    /// and closing it stops nothing.
    func startBringBack(_ request: DaemonAPI.BringBackFromRequest, from: MachineRef) async throws {
        let summary = try await client(for: from).call(DaemonAPI.Method.foldersBringBackFrom, request,
                                                        returning: DaemonAPI.BringBackSummary.self)
        // A small bring-back can end before its answer comes: its row is there already.
        if let i = bringBacks.firstIndex(where: { $0.id == summary.id }) {
            bringBacks[i].request = request
            bringBacks[i].from = from
        } else {
            bringBacks.append(FolderBringBack(state: DaemonAPI.BringBackNotification(bringBack: summary),
                                              request: request, from: from))
        }
    }

    /// Brings back again what a bring-back that stopped asked for.
    func retryBringBack(_ bringBack: FolderBringBack) async {
        guard let request = bringBack.request else { return }
        bringBacks.removeAll { $0.id == bringBack.id }
        do {
            try await startBringBack(request, from: bringBack.from)
        } catch {
            var stopped = bringBack
            stopped.state.problem = describe(error)
            bringBacks.append(stopped)
        }
    }

    /// Takes a bring-back that ended out of the Folders column.
    func putAwayBringBack(_ bringBack: FolderBringBack) {
        bringBacks.removeAll { $0.id == bringBack.id }
    }

    /// A `bringBack/changed`: the row goes a part further, or says what it did or why it
    /// stopped.
    func bringBackChanged(_ change: DaemonAPI.BringBackNotification) {
        if let i = bringBacks.firstIndex(where: { $0.id == change.bringBack.id }) {
            bringBacks[i].state = change
        } else {
            bringBacks.append(FolderBringBack(state: change, request: nil, from: .mac))
        }
    }

    /// The bring-backs this Mac's host is making, for a window that connects mid-way. Those
    /// that ended stay, until they are put away.
    func refreshBringBacks() async {
        guard let running = try? await client(for: .mac).call(DaemonAPI.Method.foldersBringingBack,
                                                   returning: [DaemonAPI.BringBackNotification].self) else { return }
        let known = Dictionary(bringBacks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        bringBacks = bringBacks.filter(\.state.finished)
            + running.map { FolderBringBack(state: $0, request: known[$0.bringBack.id]?.request,
                                            from: known[$0.bringBack.id]?.from ?? .mac) }
    }
}

/// A bring-back in the Folders column (#4640): how it goes, and, when this window started it,
/// what Retry asks for again and into which host.
struct FolderBringBack: Identifiable, Hashable {
    var state: DaemonAPI.BringBackNotification
    var request: DaemonAPI.BringBackFromRequest?
    var from: MachineRef
    var id: UUID { state.bringBack.id }
}

/// A bring-back under way (#4640), as a send's row is (#4613): the folder, and how far the
/// branches are on their way back. Once it ends it says what moved, or why it stopped (with
/// Retry), and × puts it away.
struct BringingBackRow: View {
    @Environment(AppModel.self) private var model
    let bringBack: FolderBringBack

    private var name: String { bringBack.state.bringBack.folder.lastPathComponent }
    private var machine: String { bringBack.state.bringBack.machineName }

    private var line: String {
        let s = bringBack.state
        guard s.total >= 1_000_000 else { return "Bringing back from \(machine)…" }
        return "Bringing back from \(machine): \(s.read.formatted(.byteCount(style: .file))) of \(s.total.formatted(.byteCount(style: .file)))…"
    }

    /// What a bring-back that went well did.
    private func doneLine(_ result: DaemonAPI.BringBack) -> String {
        var lines = [result.moved.isEmpty ? "This Mac already had every commit from \(machine)."
                                          : "Brought back from \(machine): \(result.moved.formatted(.list(type: .and))) moved forward."]
        if result.applied { lines.append("The uncommitted changes from \(machine) are in \(name).") }
        return lines.joined(separator: " ")
    }

    var body: some View {
        if bringBack.state.finished {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .lineLimit(1)
                        .foregroundStyle(.secondary)
                    if let problem = bringBack.state.problem {
                        SheetNote(text: problem, reservesSpace: false)
                            .help(problem)
                    } else if let result = bringBack.state.result {
                        Text(doneLine(result))
                            .appText(.fine).foregroundStyle(.secondary)
                            .lineLimit(3)
                            .help(doneLine(result))
                    }
                }
                Spacer(minLength: 4)
                if bringBack.state.problem != nil, bringBack.request != nil {
                    Button("Retry") { Task { await model.retryBringBack(bringBack) } }
                        .buttonStyle(.link)
                        .appText(.fine)
                }
                Button { model.putAwayBringBack(bringBack) } label: { Image(systemName: "xmark") }
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
            .help("\(bringBack.state.bringBack.source) on \(machine)")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Bringing \(name) back from \(bringBack.state.bringBack.source) on \(machine)")
        }
    }
}

extension View {
    /// The Bring back from ‹host›… sheet a folder's menu asks for in `requests`.
    func bringBackSheet(_ requests: WindowRequests) -> some View {
        sheet(item: Binding(get: { requests.bringBackFromHost }, set: { requests.bringBackFromHost = $0 })) { request in
            BringBackSheet(request: request).paperSheet()
        }
    }
}

/// The sheet: the host's folder, its branches to bring back, and whether its uncommitted
/// changes come too (off at first). This Mac's own changes or commits stop it.
struct BringBackSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: BringBackFromHostRequest

    @State private var here: DaemonAPI.SendFacts?
    @State private var state: DaemonAPI.ReceiveState?
    @State private var there: DaemonAPI.SendFacts?
    @State private var chosen: Set<String> = []
    @State private var includeChanges = false
    @State private var source = ""
    @State private var progress: String?
    @State private var problem: String?

    private var label: String { model.hosts.label(request.host) }
    private var name: String { request.folder.lastPathComponent }

    /// The host's uncommitted changes sit on its checked-out branch, so they come only with
    /// it, and only to a folder here that has the same branch checked out.
    private var changesCanCome: Bool {
        guard let there, let current = there.current else { return false }
        return there.hasChanges && chosen.contains(current) && here?.current == current
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Bring back \(name) from \(label)")
                .appText(.reading).fontWeight(.semibold)
            LabeledContent("Folder on \(label)") {
                TextField("~/\(name)", text: $source)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await check() } }
            }
            Text(stateLine)
                .appText(.fine).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let there { form(there) }
            // The sheet's note (#4737): it failed, or it is under way.
            SheetNote(tone: problem == nil ? .neutral : .failure, text: problem ?? progress)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(.paper)
                    .keyboardShortcut(.cancelAction)
                Button("Bring Back") { Task { await bringBack() } }
                    .buttonStyle(.paperProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBringBack)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
    }

    @ViewBuilder private func form(_ there: DaemonAPI.SendFacts) -> some View {
        Text("Branches").appText(.supporting).fontWeight(.semibold)
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(there.branches, id: \.self) { branch in
                    Toggle(isOn: Binding(get: { chosen.contains(branch) },
                                         set: { if $0 { chosen.insert(branch) } else { chosen.remove(branch) } })) {
                        Text(branch == there.current ? "\(branch) (checked out on \(label))" : branch)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 140)
        Text(macLine)
            .appText(.fine).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Toggle("Include uncommitted changes from \(label)", isOn: $includeChanges)
            .toggleStyle(.checkbox)
            .disabled(!changesCanCome)
        Text(changesLine(there))
            .appText(.fine).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stateLine: String {
        guard let state else { return "Checking \(label)…" }
        if !state.repository {
            return "\(label) has no copy of a repository here. Give the folder that Send to \(label) made."
        }
        return "Only the commits this Mac lacks come back. Branches move forward only."
    }

    private var macLine: String {
        if let current = here?.current, here?.hasChanges == true, chosen.contains(current) {
            return "\(name) has uncommitted changes on \(current) here. If \(current) must move, commit or remove them first."
        }
        return "Commits of this Mac's own on a branch, or uncommitted changes where it is checked out, stop it. Nothing is changed then."
    }

    private func changesLine(_ there: DaemonAPI.SendFacts) -> String {
        guard there.hasChanges, let current = there.current else { return "Nothing is uncommitted on \(label)." }
        guard chosen.contains(current) else {
            return "The uncommitted changes come only with \(current), the branch checked out on \(label)."
        }
        guard here?.current == current else {
            return "The uncommitted changes come only to a folder that has \(current) checked out."
        }
        return "Changed and new files come as a patch on \(current). \(name) must have no uncommitted changes."
    }

    private var canBringBack: Bool {
        progress == nil && there != nil && state?.repository == true && !chosen.isEmpty
    }

    private func load() async {
        source = "~/\(name)"
        do {
            here = try await model.sendFacts(request.folder, on: request.from)
        } catch {
            problem = model.describe(error)
            return
        }
        await check()
    }

    private func check() async {
        state = nil
        there = nil
        problem = nil
        do {
            let state = try await model.receiveState(at: source, on: request.host)
            self.state = state
            guard state.repository else { return }
            let there = try await model.sendFacts(state.folder, on: request.host)
            chosen = Set([there.current ?? there.branches.first].compactMap { $0 })
            self.there = there
        } catch {
            problem = model.describe(error)
        }
    }

    /// Starts the bring-back on this Mac's host and closes: the row under the folders says
    /// how it goes (#4640). Only a refusal before it starts stays here.
    private func bringBack() async {
        guard let there, let state else { return }
        problem = nil
        progress = "Checking \(label)…"
        do {
            try await model.startBringBack(
                DaemonAPI.BringBackFromRequest(folder: request.folder, machine: request.host.rawValue, machineName: label,
                                               source: state.folder.path, branches: there.branches.filter(chosen.contains),
                                               includeChanges: includeChanges && changesCanCome),
                from: request.from)
            dismiss()
        } catch {
            progress = nil
            problem = model.describe(error)
        }
    }
}
