import AgentsKitCore
import SwiftUI

/// The actions on a pull request's Work page (#3130), as the GitHub, GitLab and Linear views have
/// them: Merge, Approve, Rerun, the failed checks' logs, Show Diff, Close or Reopen and Labels. Each
/// goes to the machine that read the item (`forge/*`), as the person: their own click, so no
/// approval card. `wrote` reads the page again after a write. An issue's actions are in its page's
/// parts (#4400): Start Agent in the header, the status menu in the state pill's place, Labels on
/// the side panel's gear, and Close or Reopen in the comment box.
struct WorkItemActions: View {
    let model: any WorkModel
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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Wraps, so a phone's narrow page keeps every action.
            WrappingHStack(spacing: 8) {
                pullActions
                if let transitions = detail.transitions {
                    WorkStatusMenu(item: item, transitions: transitions) { transition in
                        act(DaemonAPI.Method.forgeClose, DaemonAPI.ForgeCloseRequest(node: node, transition: transition))
                    }
                } else if item.state == "open" || item.state == "closed" {
                    Button(WorkList.closeTitle(item.state)) {
                        act(DaemonAPI.Method.forgeClose,
                            DaemonAPI.ForgeCloseRequest(node: node, reopen: item.state == "open" ? nil : true))
                    }
                }
                if WorkList.takesLabels(node) { labelsMenu }
                if busy != nil { ProgressView().controlSize(.small) }
            }
            .disabled(busy != nil)
            #if os(iOS)
            .buttonStyle(.bordered)
            #endif
            if !WorkList.failedChecks(detail).isEmpty { failedChecks }
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
        if item.state == "open", !WorkList.failedChecks(detail).isEmpty {
            Button("Rerun failed") { act(DaemonAPI.Method.forgeRerun, DaemonAPI.ForgeNodeRequest(node: node)) }
        }
        Button("Show Diff") { Task { await showDiff() } }
    }

    private func merge(_ head: String, _ method: DaemonAPI.ForgeMergeMethod?, auto: Bool) {
        act(DaemonAPI.Method.forgeMerge, DaemonAPI.ForgeMergeRequest(node: node, sha: head, method: method, auto: auto ? true : nil))
    }

    private var failedChecks: some View {
        WrappingHStack(spacing: 6) {
            Text("Failed:").appText(.supporting).foregroundStyle(.secondary)
            ForEach(WorkList.failedChecks(detail), id: \.name) { check in
                Button("\(check.name) log") { Task { await readLog(check.name) } }
                    .linkStyle()
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
            said = (WorkList.failureWords(error), true)
        }
    }

    private func showDiff() async {
        busy = DaemonAPI.Method.forgeDiff
        defer { busy = nil }
        do {
            let got = try await model.forge(DaemonAPI.Method.forgeDiff, DaemonAPI.ForgeNodeRequest(node: node),
                                            returning: DaemonAPI.ForgeDiff.self, on: host)
            diff = got.appViewDiff(title: "\(WorkList.shortRef(node.ref)) \(item.title)", site: WorkList.forgeName(node.ref))
        } catch {
            said = (WorkList.failureWords(error), true)
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
        .workTask(id: node) { await loadLabels() }
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
                let close = params as? DaemonAPI.ForgeCloseRequest
                said = (WorkList.doneWords(method, done, reopened: close?.reopen == true, moved: close?.transition != nil), false)
                wrote()
            } catch {
                said = (WorkList.failureWords(error), true)
            }
        }
    }
}

/// A Jira issue's status menu (#3260), in the state pill's place: the moves its workflow allows
/// now, as Jira shows them, since a status is a step of a workflow, not open or closed. `move`
/// gets the transition's id.
struct WorkStatusMenu: View {
    let item: DaemonAPI.ForgeItem
    let transitions: [DaemonAPI.ForgeTransition]
    let move: (String) -> Void

    var body: some View {
        Menu(item.status ?? "Status") {
            if transitions.isEmpty { Text("No moves") }
            ForEach(transitions, id: \.id) { transition in
                Button(transition.name) { move(transition.id) }
            }
        }
        .fixedSize()
        .help("Move it by its workflow")
    }
}

/// The labels picker (#4400, issue.md note 12): a filter field and every label the repo has, a
/// tick on each the item has; a click adds or takes off that one (`forge/label`). A popover on
/// the Mac, a sheet on the Remote.
struct WorkLabelsPicker: View {
    let model: any WorkModel
    let host: MachineRef
    let item: DaemonAPI.ForgeItem
    /// Adds (true) or takes off (false) a label.
    let set: (String, Bool) -> Void

    @State private var choices: [DaemonAPI.ForgeLabel]?
    @State private var filter = ""
    @Environment(\.dismiss) private var dismiss

    private var shown: [DaemonAPI.ForgeLabel] {
        let words = filter.trimmingCharacters(in: .whitespaces)
        return (choices ?? []).filter { words.isEmpty || $0.name.localizedCaseInsensitiveContains(words) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Apply labels").appText(.supporting).fontWeight(.semibold)
                Spacer()
                #if os(iOS)
                Button("Done") { dismiss() }
                #endif
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            TextField("Filter labels", text: $filter)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 12).padding(.bottom, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if choices == nil {
                        Text("Loading…").foregroundStyle(.secondary).padding(12)
                    } else if shown.isEmpty {
                        Text(filter.isEmpty ? "No labels" : "No labels match").foregroundStyle(.secondary).padding(12)
                    }
                    ForEach(shown, id: \.name) { label in
                        let on = item.labels.contains { $0.name == label.name }
                        Button { set(label.name, !on) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "checkmark").opacity(on ? 1 : 0).accessibilityHidden(true)
                                WorkLabelChip(label: label)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
            }
            #if os(macOS)
            .frame(height: 260)
            #endif
        }
        .appText(.supporting)
        #if os(macOS)
        .frame(width: 280)
        #endif
        .workTask(id: item.node) { await load() }
    }

    private func load() async {
        do {
            choices = try await model.forge(DaemonAPI.Method.forgeLabels, DaemonAPI.ForgeNodeRequest(node: item.node),
                                            returning: DaemonAPI.ForgeLabels.self, on: host).labels
        } catch {
            choices = []
        }
    }
}

/// The comment box at the end of an item's timeline (#3130, #4400 note 11): the person's glyph
/// and a Markdown field, then Close issue (Close with comment, with text in the field) or Reopen
/// issue, and Comment (⌘↩). A pull request's close, and a tracker with a status menu, have Comment
/// only. What a write did, or why not, is the line under the buttons.
struct WorkCommentBox: View {
    let model: any WorkModel
    let host: MachineRef
    let node: DaemonAPI.LineageNode
    /// open or closed: the issue's close is here; nil when it is not (a pull request, a tracker's status).
    var closes: String?
    /// A narrow page: no avatar column, so the box takes the width.
    var compact = false
    /// What the page's last write did, under the buttons.
    var said: (words: String, failed: Bool)?
    /// After a write: what it did, and whether it failed.
    let wrote: (String, Bool) -> Void

    @State private var text = ""
    @State private var sending = false

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if !compact {
                // The person's avatar comes with the forge's login for them (#4363); a person's glyph till then.
                Image(systemName: "person.crop.circle.fill")
                    // Sized to the timeline's avatar column, not to a text step: a marked decorative glyph.
                    .font(.system(size: WorkTimelineEntry<EmptyView, EmptyView>.column))
                    .foregroundStyle(.tertiary)
                    .frame(width: WorkTimelineEntry<EmptyView, EmptyView>.column)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $text)
                    .appText(.reading)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 96)
                    .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.raised))
                    .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Paper.rule))
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Comment, in Markdown").appText(.reading).foregroundStyle(.tertiary)
                                .padding(.horizontal, 11).padding(.vertical, 6)
                                .allowsHitTesting(false)
                        }
                    }
                    .accessibilityLabel("New comment")
                HStack(spacing: 8) {
                    if sending { ProgressView().controlSize(.small) }
                    Spacer()
                    if let closes { closeButton(closes) }
                    Button("Comment") { Task { await comment() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || empty)
                        .keyboardShortcut(.return, modifiers: .command)
                }
                .disabled(sending)
                if let said {
                    Text(said.words).appText(.supporting)
                        .foregroundStyle((said.failed ? StateTint.failure : .none).style(or: .secondary))
                        .textSelection(.enabled)
                }
            }
        }
    }

    /// Close issue, or Close with comment when the field has text: as on GitHub, so a close can
    /// say why. Close as not planned comes with `forge/close`'s reason (#4400, task 5).
    @ViewBuilder
    private func closeButton(_ state: String) -> some View {
        if state == "open" {
            Button(empty ? "Close issue" : "Close with comment", systemImage: "checkmark.circle") { Task { await close(reopen: false) } }
                .help("Close it as completed")
        } else {
            Button(empty ? "Reopen issue" : "Reopen with comment", systemImage: "arrow.uturn.backward.circle") {
                Task { await close(reopen: true) }
            }
        }
    }

    private func comment() async -> Bool {
        sending = true
        defer { sending = false }
        do {
            let done = try await model.forge(DaemonAPI.Method.forgeComment, DaemonAPI.ForgeCommentRequest(node: node, body: text),
                                             returning: DaemonAPI.ForgeDone.self, on: host)
            text = ""
            wrote(WorkList.doneWords(DaemonAPI.Method.forgeComment, done), false)
            return true
        } catch {
            wrote(WorkList.failureWords(error), true)
            return false
        }
    }

    /// The comment first, when there is one, then the close or the reopen.
    private func close(reopen: Bool) async {
        if !empty {
            guard await comment() else { return }
        }
        sending = true
        defer { sending = false }
        do {
            let done = try await model.forge(DaemonAPI.Method.forgeClose,
                                             DaemonAPI.ForgeCloseRequest(node: node, reopen: reopen ? true : nil),
                                             returning: DaemonAPI.ForgeDone.self, on: host)
            wrote(WorkList.doneWords(DaemonAPI.Method.forgeClose, done, reopened: reopen), false)
        } catch {
            wrote(WorkList.failureWords(error), true)
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
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
    }
}
