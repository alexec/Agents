import AgentsKitCore
import SwiftUI

/// A pull request's merge box (#4406, pull-request.md note 10): a bordered box at the end of the
/// timeline (at the top of a narrow page) with a row for the review, the checks and conflicts,
/// each with a glyph in its state's colour, then Merge ▾, Approve and Rerun failed. The checks
/// list opens with Show all, and is open from the start when a check failed; a failed check has
/// Log (`forge/log`). On the iPhone (#4407) the checks row pushes the Checks page in place of
/// the list, and Merge ▾ takes the width. Each write goes to the machine that read the item, as
/// the person: their own click, so no approval card. `wrote` reads the page again after a write.
struct WorkMergeBox: View {
    let model: any WorkModel
    let host: MachineRef
    let detail: DaemonAPI.ForgeItemDetail
    let box: WorkLook.MergeBox
    /// A machine of the person's writes to the forge: else the rows only, and why no buttons.
    let writes: Bool
    var compact = false
    let wrote: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var busy: String?
    @State private var said: (words: String, failed: Bool)?
    @State private var log: WorkLog?
    @State private var showsChecks: Bool?
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var checksPage = false
    /// The iPhone: the Checks page, and full-width buttons (#4407, pull-request.md note 17).
    private var phone: Bool { compact && sizeClass == .compact }
    #else
    private let phone = false
    #endif

    private var item: DaemonAPI.ForgeItem { detail.item }
    private var node: DaemonAPI.LineageNode { item.node }
    private var checks: [DaemonAPI.ForgeCheck] { WorkLook.checksInOrder(detail.checks ?? []) }
    private var checksOpen: Bool { showsChecks ?? box.checksOpen }

    var body: some View {
        Group {
            if compact {
                content
            } else {
                WorkTimelineEntry {
                    WorkStateIcon(kind: "pr", state: "open", draft: item.draft == true, onFill: true)
                        .appText(.fine)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill((item.draft == true ? WorkLook.Glyph.prDraft : .prOpen).tone.color))
                } content: {
                    content
                }
            }
        }
        .sheet(item: $log) { log in WorkLogSheet(log: log) }
        #if os(iOS)
        .navigationDestination(isPresented: $checksPage) {
            WorkChecksPage(model: model, host: host, detail: detail, writes: writes, wrote: wrote).paperGround()
        }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(box.rows, id: \.kind) { row in
                #if os(iOS)
                if phone, row.kind == .checks, !checks.isEmpty {
                    Button { checksPage = true } label: { rowView(row) }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens the checks")
                } else {
                    rowView(row)
                }
                #else
                rowView(row)
                #endif
                if row.kind == .checks, checksOpen, !phone, !checks.isEmpty { checksList }
                Divider()
            }
            buttons.padding(12)
        }
        .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.raised))
        .overlay(RoundedRectangle(cornerRadius: Paper.Radius.card).strokeBorder(Self.tint(box.border) ?? Paper.rule,
                                                                               lineWidth: box.border == .info ? 1 : 1.5))
        .clipShape(RoundedRectangle(cornerRadius: Paper.Radius.card))
    }

    private func rowView(_ row: WorkLook.MergeRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: Self.symbol(row))
                .foregroundStyle(Self.tint(row.sign).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).appText(.reading).fontWeight(.semibold)
                if let line = row.line {
                    Text(line).appText(.supporting).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.kind == .checks, !checks.isEmpty {
                if phone {
                    // *15 ›*: the row is the button that pushes the Checks page.
                    HStack(spacing: 4) {
                        Text("\(checks.count)").monospacedDigit()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .appText(.supporting).foregroundStyle(.secondary)
                } else {
                    Button(checksOpen ? "Hide" : "Show all") { showsChecks = !checksOpen }
                        .linkStyle()
                        .appText(.supporting)
                }
            }
        }
        .padding(12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// One line per check: its glyph, its name, and Log on a failed one (Details, its page on
    /// the forge, on the others that have one).
    private var checksList: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                HStack(spacing: 8) {
                    Image(systemName: Self.checkSymbol(check.state))
                        .foregroundStyle(Self.tint(Self.checkSign(check.state)).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                        .frame(width: 16)
                        .accessibilityLabel(check.state)
                    Text(check.name).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if check.state == "failing", writes {
                        Button("Log") { Task { await readLog(check.name) } }
                            .linkStyle()
                            .help("The end of this check's log")
                    } else if let url = check.url.flatMap(URL.init(string:)) {
                        Button("Details") { openURL(url) }.linkStyle()
                    }
                }
                .appText(.supporting)
            }
        }
        .padding(.leading, 38).padding(.trailing, 12).padding(.bottom, 12)
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !writes {
                Text(WorkLook.noWriter(node.ref)).appText(.supporting).foregroundStyle(.secondary)
            } else if item.draft == true {
                Text(WorkLook.readyOnForge(node.ref)).appText(.supporting).foregroundStyle(.secondary)
            } else if phone {
                phoneButtons
            } else {
                WrappingHStack(spacing: 8) {
                    if box.merges, let head = detail.head { mergeButton(head) }
                    if box.resolve, let url = item.url.flatMap(URL.init(string:)) {
                        Button(WorkLook.resolveOnForge(node.ref)) { openURL(url.appendingPathComponent("conflicts")) }
                    }
                    if box.approves, let head = detail.head {
                        Button("Approve", systemImage: "checkmark") {
                            act(DaemonAPI.Method.forgeApprove, DaemonAPI.ForgeApproveRequest(node: node, sha: head))
                        }
                    }
                    if box.reruns {
                        Button("Rerun failed", systemImage: "arrow.clockwise") {
                            act(DaemonAPI.Method.forgeRerun, DaemonAPI.ForgeNodeRequest(node: node))
                        }
                    }
                    if busy != nil { ProgressView().controlSize(.small) }
                }
                .disabled(busy != nil)
                #if os(iOS)
                .buttonStyle(.bordered)
                #endif
            }
            if let said {
                Text(said.words).appText(.supporting).foregroundStyle((said.failed ? StateTint.failure : .none).style(or: .secondary))
                    .textSelection(.enabled)
            }
        }
    }

    /// The iPhone's buttons (pull-request.md, Narrow): Merge ▾ the full width, or with Approve
    /// beside it (Approve its own width, never wrapped; Merge the rest); Approve and Rerun failed
    /// side by side when both show.
    @ViewBuilder
    private var phoneButtons: some View {
        let merges = box.merges && detail.head != nil
        let resolve = box.resolve ? item.url.flatMap(URL.init(string:)) : nil
        let approves = box.approves && detail.head != nil
        // Approve goes beside Merge only when Rerun failed does not need the row under it.
        let approveBeside = approves && !box.reruns && (merges || resolve != nil)
        let gap: CGFloat = 8
        VStack(spacing: gap) {
            if merges || resolve != nil {
                HStack(spacing: gap) {
                    Group {
                        if merges, let head = detail.head {
                            mergeButton(head, full: true)
                        } else if let resolve {
                            Button { openURL(resolve.appendingPathComponent("conflicts")) } label: {
                                Text(WorkLook.resolveOnForge(node.ref)).frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    if approveBeside { approveButton(glyph: false).fixedSize() }
                }
            }
            if (approves && !approveBeside) || box.reruns {
                HStack(spacing: gap) {
                    if approves && !approveBeside { approveButton(glyph: true) }
                    if box.reruns { rerunButton }
                }
            }
            if busy != nil { ProgressView().controlSize(.small) }
        }
        .disabled(busy != nil)
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    /// Approve; beside Merge it is its word alone, so Merge keeps its words.
    private func approveButton(glyph: Bool) -> some View {
        Button {
            if let head = detail.head {
                act(DaemonAPI.Method.forgeApprove, DaemonAPI.ForgeApproveRequest(node: node, sha: head))
            }
        } label: {
            Group {
                if glyph { Label("Approve", systemImage: "checkmark") } else { Text("Approve") }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var rerunButton: some View {
        Button { act(DaemonAPI.Method.forgeRerun, DaemonAPI.ForgeNodeRequest(node: node)) } label: {
            Label("Rerun failed", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
        }
    }

    /// Merge ▾: the repo's first method (Merge when checks pass while they run), the menu the
    /// others, then Merge when checks pass. Green when it merges now, the accent while it waits.
    /// `full`: the main button takes the width (the iPhone).
    private func mergeButton(_ head: String, full: Bool = false) -> some View {
        let methods = detail.mergeMethods ?? []
        let waits = box.waits
        // A Menu with a primary action draws grey on the Mac whatever its tint: a prominent
        // button and a menu beside it, as one split button.
        return HStack(spacing: 1) {
            Button { merge(head, methods.first, auto: waits) } label: {
                // Beside Approve on a phone, *Squash and merge* shrinks a little before it cuts.
                Text(WorkLook.mergeMain(methods, waits: waits)).lineLimit(1).minimumScaleFactor(full ? 0.8 : 1)
                    .frame(maxWidth: full ? .infinity : nil, maxHeight: full ? .infinity : nil)
            }
            Menu {
                ForEach(methods.dropFirst(), id: \.self) { method in
                    Button(WorkList.mergeButton(method, waits: waits)) { merge(head, method, auto: waits) }
                }
                if !waits {
                    Divider()
                    Button("Merge when checks pass") { merge(head, methods.first, auto: true) }
                }
            } label: {
                // The full-width pair is one height: a Menu's label is shorter than a button's.
                Image(systemName: "chevron.down").imageScale(.small).frame(maxHeight: full ? .infinity : nil)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("More ways to merge")
            .disabled(methods.count < 2 && waits)
        }
        .buttonStyle(.borderedProminent)
        .tint(waits ? Paper.accent : WorkLook.Glyph.prOpen.tone.color)
        .fixedSize(horizontal: !full, vertical: true)
    }

    private func merge(_ head: String, _ method: DaemonAPI.ForgeMergeMethod?, auto: Bool) {
        act(DaemonAPI.Method.forgeMerge, DaemonAPI.ForgeMergeRequest(node: node, sha: head, method: method, auto: auto ? true : nil))
    }

    private func readLog(_ check: String) async {
        busy = DaemonAPI.Method.forgeLog
        said = nil
        defer { busy = nil }
        do {
            log = try await WorkLog.read(check, of: node, model: model, on: host)
        } catch {
            said = (WorkList.failureWords(error), true)
        }
    }

    private func act(_ method: String, _ params: some Encodable & Sendable) {
        Task {
            busy = method
            defer { busy = nil }
            do {
                let done = try await model.forge(method, params, returning: DaemonAPI.ForgeDone.self, on: host)
                said = (WorkList.doneWords(method, done), false)
                wrote()
            } catch {
                said = (WorkList.failureWords(error), true)
            }
        }
    }

    // MARK: Glyphs and colours

    /// Amber: waiting on a person or a run, as GitHub draws it.
    static let amber = Color(light: 0x9A6700, dark: 0xD29922)

    static func tint(_ sign: WorkLook.MergeSign) -> Color? {
        switch sign {
        case .pass: WorkLook.Glyph.prOpen.tone.color
        case .fail: WorkLook.Glyph.prClosed.tone.color
        case .wait: amber
        case .info: nil
        }
    }

    static func symbol(_ row: WorkLook.MergeRow) -> String {
        switch (row.kind, row.sign) {
        case (.draft, _): "doc"
        case (.autoMerge, _): "clock"
        case (.review, .wait): "eye"
        case (.conflicts, .fail): "exclamationmark.triangle.fill"
        case (_, .fail): "xmark.circle.fill"
        case (_, .wait): "circle.fill"
        default: "checkmark.circle.fill"
        }
    }

    static func checkSign(_ state: String) -> WorkLook.MergeSign {
        switch state {
        case "passing": .pass
        case "failing": .fail
        case "running": .wait
        default: .info
        }
    }

    static func checkSymbol(_ state: String) -> String {
        switch state {
        case "passing": "checkmark"
        case "failing": "xmark"
        case "running": "circle.fill"
        default: "minus.circle"
        }
    }
}

/// Files changed 6 (#4406, pull-request.md note 5): a bordered button at the title's trailing end
/// (a full-width row on a narrow page) that opens the diff (`forge/diff`) as a sheet.
struct WorkFilesChanged: View {
    let model: any WorkModel
    let host: MachineRef
    let detail: DaemonAPI.ForgeItemDetail
    var compact = false

    @Environment(\.openURL) private var openURL
    @State private var diff: AppViewDiff?
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if compact {
                Button { Task { await showDiff() } } label: {
                    HStack {
                        Label("Files changed", systemImage: "doc.on.doc")
                        Spacer()
                        if loading { ProgressView().controlSize(.small) }
                        if let n = detail.filesChanged { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
                    }
                    .appText(.supporting)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(RoundedRectangle(cornerRadius: Paper.Radius.card).fill(Paper.well))
            } else {
                Button { Task { await showDiff() } } label: {
                    HStack(spacing: 6) {
                        Label(WorkLook.filesChanged(detail.filesChanged), systemImage: "doc.on.doc")
                        if loading { ProgressView().controlSize(.small) }
                    }
                }
                .buttonStyle(.bordered)
                .help("The pull request's diff")
            }
            if let problem {
                Text(problem).appText(.supporting).foregroundStyle(StateTint.failure.style(or: .secondary))
            }
        }
        .disabled(loading)
        .sheet(item: $diff) { diff in
            AppViewDiffPage(diff: diff, openLink: { openURL($0) })
        }
    }

    private func showDiff() async {
        loading = true
        problem = nil
        defer { loading = false }
        let item = detail.item
        do {
            let got = try await model.forge(DaemonAPI.Method.forgeDiff, DaemonAPI.ForgeNodeRequest(node: item.node),
                                            returning: DaemonAPI.ForgeDiff.self, on: host)
            diff = got.appViewDiff(title: "\(WorkList.shortRef(item.node.ref)) \(item.title)", site: WorkList.forgeName(item.node.ref))
        } catch {
            problem = WorkList.failureWords(error)
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
/// issue, and Comment (⌘↩); on a pull request Close pull request or Reopen pull request (#4406). A
/// merged pull request, and a tracker with a status menu, have Comment only. What a write did, or
/// why not, is the line under the buttons.
struct WorkCommentBox: View {
    let model: any WorkModel
    let host: MachineRef
    let node: DaemonAPI.LineageNode
    /// open or closed: the item's close is here; nil when it is not (a merged pull request, a tracker's status).
    var closes: String?
    /// What Close and Reopen name: issue, or pull request.
    var noun = "issue"
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
    /// say why. Close as not planned comes with `forge/close`'s reason (#4400, task 5); a pull
    /// request has none.
    @ViewBuilder
    private func closeButton(_ state: String) -> some View {
        if state == "open" {
            Button(empty ? "Close \(noun)" : "Close with comment", systemImage: noun == "issue" ? "checkmark.circle" : "xmark.circle") {
                Task { await close(reopen: false) }
            }
            .help(noun == "issue" ? "Close it as completed" : "Close it without merging")
        } else {
            Button(empty ? "Reopen \(noun)" : "Reopen with comment", systemImage: "arrow.uturn.backward.circle") {
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

    /// The end of a failed check's log, from the machine that read the item (`forge/log`).
    static func read(_ check: String, of node: DaemonAPI.LineageNode, model: any WorkModel, on host: MachineRef) async throws -> WorkLog {
        let got = try await model.forge(DaemonAPI.Method.forgeLog, DaemonAPI.ForgeLogRequest(node: node, check: check),
                                        returning: DaemonAPI.ForgeLog.self, on: host)
        return WorkLog(title: check, text: got.text)
    }
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
            // `forge/log` gives the end of the log, where a failure says why: open there.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #else
        .paperSheet()
        .presentationDetents([.medium, .large])
        #endif
    }
}

#if os(iOS)
/// The Checks page on the iPhone (#4407, pull-request.md note 17), pushed by the merge box's
/// checks row: *1 failed, 12 passed, 1 running*, Rerun failed the full width, then a row per check,
/// the failed first. A tap on a failed check opens the end of its log in a sheet (`forge/log`
/// reads only a failed one's); on another, its page on the forge. A check's time comes with the
/// forge's check times (#4406, missing fields).
struct WorkChecksPage: View {
    let model: any WorkModel
    let host: MachineRef
    let detail: DaemonAPI.ForgeItemDetail
    let writes: Bool
    let wrote: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var busy: String?
    @State private var said: (words: String, failed: Bool)?
    @State private var log: WorkLog?

    private var node: DaemonAPI.LineageNode { detail.item.node }
    private var checks: [DaemonAPI.ForgeCheck] { WorkLook.checksInOrder(detail.checks ?? []) }

    var body: some View {
        List {
            Section {
                if let line = WorkLook.checksRow(detail.checks, summary: detail.item.checks)?.line {
                    Text(line).appText(.supporting).foregroundStyle(.secondary).monospacedDigit()
                }
                if writes, !WorkList.failedChecks(detail).isEmpty {
                    Button { rerun() } label: {
                        HStack {
                            Label("Rerun failed", systemImage: "arrow.clockwise")
                            if busy == DaemonAPI.Method.forgeRerun { ProgressView() }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(busy != nil)
                }
                if let said {
                    Text(said.words).appText(.supporting)
                        .foregroundStyle((said.failed ? StateTint.failure : .none).style(or: .secondary))
                }
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            Section {
                ForEach(Array(checks.enumerated()), id: \.offset) { _, check in
                    row(check)
                }
            }
            .listRowBackground(Paper.raised)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Checks")
        .navigationSubtitle("\(WorkList.shortRef(node.ref)) · \(checks.count)")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $log) { log in WorkLogSheet(log: log) }
    }

    /// The glyph, the name, *running* or *skipped* (a time comes with the forge's), and a chevron
    /// on one that opens something.
    @ViewBuilder
    private func row(_ check: DaemonAPI.ForgeCheck) -> some View {
        let logs = check.state == "failing" && writes
        let url = check.url.flatMap(URL.init(string:))
        let line = HStack(spacing: 10) {
            Image(systemName: WorkMergeBox.checkSymbol(check.state))
                .foregroundStyle(WorkMergeBox.tint(WorkMergeBox.checkSign(check.state)).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                .frame(width: 18)
                .accessibilityLabel(check.state)
            Text(check.name).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            if ["running", "skipped"].contains(check.state) {
                Text(check.state).foregroundStyle(.secondary)
            }
            if busy == check.name { ProgressView() }
            if logs || url != nil {
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
        }
        .appText(.reading)
        .contentShape(Rectangle())
        if logs {
            Button { Task { await readLog(check.name) } } label: { line }
                .buttonStyle(.plain)
                .disabled(busy != nil)
                .accessibilityHint("Opens the end of its log")
        } else if let url {
            Button { openURL(url) } label: { line }
                .buttonStyle(.plain)
                .accessibilityHint(WorkList.openOnWords(node.ref))
        } else {
            line
        }
    }

    private func readLog(_ check: String) async {
        busy = check
        said = nil
        defer { busy = nil }
        do {
            log = try await WorkLog.read(check, of: node, model: model, on: host)
        } catch {
            said = (WorkList.failureWords(error), true)
        }
    }

    private func rerun() {
        Task {
            busy = DaemonAPI.Method.forgeRerun
            defer { busy = nil }
            do {
                let done = try await model.forge(DaemonAPI.Method.forgeRerun, DaemonAPI.ForgeNodeRequest(node: node),
                                                 returning: DaemonAPI.ForgeDone.self, on: host)
                said = (WorkList.doneWords(DaemonAPI.Method.forgeRerun, done), false)
                wrote()
            } catch {
                said = (WorkList.failureWords(error), true)
            }
        }
    }
}
#endif
