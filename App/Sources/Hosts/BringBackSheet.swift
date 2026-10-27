import AgentsKitCore
import SwiftUI

/// Bring back from ‹host›… (#1473), the reverse of Send to ‹host›… (#1123): a host's
/// branches come back into the repository at `folder` on this Mac, forward only. `from` is
/// this Mac's host, which takes them in, since the window is sandboxed and reads no
/// repository itself.
struct BringBackFromHostRequest: Identifiable, Hashable {
    let folder: URL
    let from: MachineRef
    let host: MachineRef
    var id: String { "\(host.rawValue) \(folder.path)" }
}

extension AppModel {
    /// Has `host` pack `branches` of its copy at `source`, less the commits this Mac has,
    /// with its uncommitted changes when `includeChanges`, and has this Mac's host `from`
    /// take them into the repository at `folder`. Each part goes through the window.
    func bringBack(_ folder: URL, from: MachineRef, host: MachineRef, source: URL, branches: [String], includeChanges: Bool,
                   patchOn: String?, progress: @escaping @MainActor (String) -> Void) async throws -> DaemonAPI.BringBack {
        let label = hosts.label(host)
        let mac = client(for: from), there = client(for: host)
        let here = try await receiveState(at: folder.path, on: from)
        progress("Making the bundle on \(label)…")
        let pack = try await there.callWhileAnswering(
            DaemonAPI.Method.foldersSendPack,
            DaemonAPI.SendPackRequest(folder: source, branches: branches, leavingOut: here.heads, includeChanges: includeChanges),
            checkingEvery: .seconds(10)).decode(DaemonAPI.SendPack.self)
        let (bundle, patch) = try await relay(pack, from: there, to: mac, verb: "Bringing back", progress: progress)
        progress("Bringing it into this Mac's repository…")
        return try await mac.callWhileAnswering(
            DaemonAPI.Method.foldersBringBack,
            DaemonAPI.BringBackRequest(folder: folder, bundle: bundle, patch: patch, patchOn: patch == nil ? nil : patchOn,
                                       branches: pack.commits),
            checkingEvery: .seconds(10)).decode(DaemonAPI.BringBack.self)
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
    @State private var done: String?

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
            if done == nil {
                LabeledContent("Folder on \(label)") {
                    TextField("~/\(name)", text: $source)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await check() } }
                }
                Text(stateLine)
                    .appText(.fine).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let there { form(there) }
            }
            if let problem {
                Text(problem)
                    .appText(.fine).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let done {
                Text(done).appText(.supporting)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let progress {
                Text(progress).appText(.fine).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                if done != nil {
                    Button("Done") { dismiss() }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .buttonStyle(.paper)
                        .keyboardShortcut(.cancelAction)
                        .disabled(progress != nil)
                    Button("Bring Back") { Task { await bringBack() } }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canBringBack)
                }
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

    private func bringBack() async {
        guard let there, let state else { return }
        problem = nil
        progress = "Checking \(label)…"
        do {
            let result = try await model.bringBack(
                request.folder, from: request.from, host: request.host, source: state.folder,
                branches: there.branches.filter(chosen.contains), includeChanges: includeChanges && changesCanCome,
                patchOn: there.current) { progress = $0 }
            progress = nil
            var lines = [result.moved.isEmpty ? "This Mac already had every commit."
                                              : "Moved forward: \(result.moved.formatted(.list(type: .and)))."]
            if result.applied { lines.append("The uncommitted changes from \(label) are in \(name).") }
            done = lines.joined(separator: " ")
        } catch {
            progress = nil
            problem = model.describe(error)
        }
    }
}
