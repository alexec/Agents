import AgentsKitCore
import SwiftUI

/// The actions on an issue's or a pull request's Work page (#3130), as the GitHub, GitLab and
/// Linear views have them: Start Agent, labels and Close or Reopen on an issue; Merge, Approve,
/// Rerun, the failed checks' logs and Show Diff on a pull request; a comment on either. Each goes
/// to the machine that read the item (`forge/*`), as the person: their own click, so no approval
/// card. `wrote` reads the page again after a write.
struct WorkItemActions: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let host: MachineRef
    let detail: DaemonAPI.ForgeItemDetail
    let wrote: () -> Void

    @State private var busy: String?
    @State private var said: (words: String, failed: Bool)?
    @State private var labelChoices: [DaemonAPI.ForgeLabel]?
    @State private var log: WorkLog?
    @State private var diff: AppViewDiff?

    private var item: DaemonAPI.ForgeItem { detail.item }
    private var node: DaemonAPI.LineageNode { item.node }
    private var isPR: Bool { node.kind == "pr" }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if isPR { pullActions } else { issueActions }
                if item.state == "open" || item.state == "closed" {
                    Button(WorkList.closeTitle(item.state)) {
                        act(DaemonAPI.Method.forgeClose,
                            DaemonAPI.ForgeCloseRequest(node: node, reopen: item.state == "open" ? nil : true))
                    }
                }
                labelsMenu
                if busy != nil { ProgressView().controlSize(.small) }
            }
            .disabled(busy != nil)
            if isPR, !WorkList.failedChecks(detail).isEmpty { failedChecks }
            if let said {
                Text(said.words).appText(.supporting).foregroundStyle((said.failed ? StateTint.failure : .none).style(or: .secondary))
                    .textSelection(.enabled)
            }
        }
        .sheet(item: $log) { log in WorkLogSheet(log: log) }
        .sheet(item: $diff) { diff in
            AppViewDiffPage(diff: diff, openLink: { openURL($0) })
        }
    }

    // MARK: An issue's

    @ViewBuilder
    private var issueActions: some View {
        if let start = detail.start {
            Button("Start Agent") { startAgent(start) }
                .buttonStyle(.borderedProminent)
                .help("The new-agent form in this issue's folder, filled in for it")
        }
    }

    private func startAgent(_ start: DaemonAPI.ForgeStart) {
        guard let folder = item.folder else {
            said = ("No folder on this machine is on this issue's repo.", true)
            return
        }
        let offer = AppViewStart(prompt: start.prompt, labels: start.labels, worktree: start.worktree)
        if let why = model.offerStart(offer, in: FolderKey(host: host, folder: URL(fileURLWithPath: folder))) {
            said = (why, true)
        }
    }

    // MARK: A pull request's

    @ViewBuilder
    private var pullActions: some View {
        if item.state == "open", let head = detail.head {
            let methods = detail.mergeMethods ?? []
            let waits = WorkList.mergeWaits(detail)
            Menu(WorkList.mergeButton(methods.first, waits: waits)) {
                ForEach(methods.dropFirst(), id: \.self) { method in
                    Button(WorkList.mergeButton(method, waits: waits)) { merge(head, method, auto: waits) }
                }
                if !waits {
                    Divider()
                    Button("Merge when checks pass") { merge(head, methods.first, auto: true) }
                }
            } primaryAction: {
                merge(head, methods.first, auto: waits)
            }
            .fixedSize()
            Button("Approve") {
                act(DaemonAPI.Method.forgeApprove, DaemonAPI.ForgeApproveRequest(node: node, sha: head))
            }
        }
        if !WorkList.failedChecks(detail).isEmpty {
            Button("Rerun failed") { act(DaemonAPI.Method.forgeRerun, DaemonAPI.ForgeNodeRequest(node: node)) }
        }
        Button("Show Diff") { Task { await showDiff() } }
    }

    private func merge(_ head: String, _ method: DaemonAPI.ForgeMergeMethod?, auto: Bool) {
        act(DaemonAPI.Method.forgeMerge, DaemonAPI.ForgeMergeRequest(node: node, sha: head, method: method, auto: auto ? true : nil))
    }

    private var failedChecks: some View {
        HStack(spacing: 6) {
            Text("Failed:").appText(.supporting).foregroundStyle(.secondary)
            ForEach(WorkList.failedChecks(detail), id: \.name) { check in
                Button("\(check.name) log") { Task { await readLog(check.name) } }
                    .buttonStyle(.link)
                    .help("The end of this check's log")
            }
        }
    }

    private func readLog(_ check: String) async {
        busy = DaemonAPI.Method.forgeLog
        defer { busy = nil }
        do {
            let got = try await model.forge(DaemonAPI.Method.forgeLog, DaemonAPI.ForgeLogRequest(node: node, check: check),
                                            returning: DaemonAPI.ForgeLog.self, on: host)
            log = WorkLog(title: check, text: got.text)
        } catch {
            said = (error.localizedDescription, true)
        }
    }

    private func showDiff() async {
        busy = DaemonAPI.Method.forgeDiff
        defer { busy = nil }
        do {
            let got = try await model.forge(DaemonAPI.Method.forgeDiff, DaemonAPI.ForgeNodeRequest(node: node),
                                            returning: DaemonAPI.ForgeDiff.self, on: host)
            diff = got.appViewDiff(title: "\(WorkList.shortRef(node.ref)) \(item.title)")
        } catch {
            said = (error.localizedDescription, true)
        }
    }

    // MARK: Labels

    private var labelsMenu: some View {
        Menu("Labels") {
            if let labelChoices {
                if labelChoices.isEmpty { Text("No labels") }
                ForEach(labelChoices, id: \.name) { label in
                    let on = item.labels.contains { $0.name == label.name }
                    Toggle(label.name, isOn: Binding(get: { on }, set: { add in
                        act(DaemonAPI.Method.forgeLabel,
                            DaemonAPI.ForgeLabelRequest(node: node, add: add ? [label.name] : nil, remove: add ? nil : [label.name]))
                    }))
                }
            } else {
                Text("Loading…")
            }
        }
        .fixedSize()
        .task(id: node) { await loadLabels() }
    }

    private func loadLabels() async {
        do {
            labelChoices = try await model.forge(DaemonAPI.Method.forgeLabels, DaemonAPI.ForgeNodeRequest(node: node),
                                                 returning: DaemonAPI.ForgeLabels.self, on: host).labels
        } catch {
            labelChoices = []
        }
    }

    // MARK: Writing

    private func act(_ method: String, _ params: some Encodable & Sendable) {
        Task {
            busy = method
            defer { busy = nil }
            do {
                let done = try await model.forge(method, params, returning: DaemonAPI.ForgeDone.self, on: host)
                said = (WorkList.doneWords(method, done), false)
                wrote()
            } catch {
                said = (error.localizedDescription, true)
            }
        }
    }
}

/// A comment box under an item's comments (#3130): Markdown, sent as the person.
struct WorkCommentBox: View {
    @Environment(AppModel.self) private var model
    let host: MachineRef
    let node: DaemonAPI.LineageNode
    let wrote: () -> Void

    @State private var text = ""
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $text)
                .appText(.reading)
                .frame(minHeight: 70, maxHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .accessibilityLabel("Comment")
            HStack {
                if let failure { Text(failure).appText(.supporting).tinted(.failure) }
                Spacer()
                Button(sending ? "Sending…" : "Comment") { Task { await send() } }
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private func send() async {
        sending = true
        failure = nil
        defer { sending = false }
        do {
            _ = try await model.forge(DaemonAPI.Method.forgeComment, DaemonAPI.ForgeCommentRequest(node: node, body: text),
                                      returning: DaemonAPI.ForgeDone.self, on: host)
            text = ""
            wrote()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// A failed check's log, as `forge/log` gives it.
struct WorkLog: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

private struct WorkLogSheet: View {
    let log: WorkLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(log.title).appText(.reading).fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(log.text)
                    .appText(.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
    }
}
