import AgentsKitCore
import CodeText
import SwiftUI

/// One change waiting for an OK, on a page of its own (#1472): a workflow, a guarded
/// `.agents` file, a connector's entry or a plugin's files. It opens in the detail column
/// on a Mac and an iPad and is pushed on an iPhone, where a card or a sheet cut a long
/// file off at a few hundred points.
///
/// The header says what it is, where, who changed it and since when; then what the answers
/// do; then the whole change, which the page scrolls; and the host's answers in a bar
/// that stays at the foot. The client says how to read and answer, as it did for the card
/// and the sheet before, so the page holds no model of its own. The version answered is
/// the one read: a change since is refused, and the refusal is said here.
struct ReviewPage: View {
    let approval: Approval
    /// Which folder it is in, as the sidebar names it.
    var place: String?
    /// What it is; nil when it could not be read, which the client has said.
    let read: () async -> GuardedChangeReading?
    /// The answer, of the version read; nil when it went, or why not.
    let answer: (Approval.Action, _ digest: String?, _ note: String?) async -> String?
    var isOffline = false
    /// Opens the session that made the change; nil where the client cannot.
    var openAgent: ((UUID) -> Void)?
    /// The answer went: the client leaves the page.
    let done: () -> Void

    @AppStorage("reviewDiffLayout", store: WindowDefaults.store) private var layout = FileDiffView.Layout.unified
    @State private var reading: GuardedChangeReading?
    @State private var rows: [DiffRow] = []
    @State private var loaded = false
    @State private var busy = false
    @State private var asking = false
    @State private var note = ""
    @State private var refusal: String?
    @State private var width: CGFloat = 0

    /// Wide enough for the old file beside the new.
    private var wide: Bool { width >= 820 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Text(approval.explanation)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let reading {
                    diffHeading(reading)
                    if rows.isEmpty {
                        Text("No lines changed.")
                            .appText(.supporting)
                            .foregroundStyle(.secondary)
                    } else {
                        FileDiffView(rows: rows, path: reading.path, oldText: reading.approved,
                                     newText: reading.current, layout: wide ? layout : .unified)
                    }
                    if reading.isCut {
                        Text("The change is longer than \(GuardedDiffLine.limit) lines. The rest is not shown here; "
                             + "open \(reading.path) in the folder to read it all.")
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if !loaded {
                    ProgressView().controlSize(.small)
                } else {
                    Text("The change could not be read.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .navigationTitle(approval.title)
        #if os(iOS)
        // The header says the title large; the bar says it once, small.
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: approval) {
            reading = await read()
            rows = reading.map(Self.rows) ?? []
            loaded = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ApprovalMark(kind: approval.kind)
                Text(approval.title)
                    .appText(.title).fontWeight(.semibold)
                    .lineLimit(2)
            }
            HStack(spacing: 6) {
                Text([approval.kindWord, place].compactMap { $0 }.joined(separator: " · "))
                if let since = approval.since {
                    Text("·")
                    ActivityTime(date: since)
                }
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(approval.line)
                    .appText(.supporting)
                if let id = approval.agentID, let openAgent {
                    Button("Open Session") { openAgent(id) }
                        .buttonStyle(.borderless)
                        .appText(.supporting)
                }
            }
        }
    }

    private func diffHeading(_ reading: GuardedChangeReading) -> some View {
        let counts = reading.counts
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(reading.path)
                .appText(.fine)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Text("+\(counts.added) −\(counts.removed)")
                .appText(.fine)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(counts.added) lines added, \(counts.removed) removed")
            Spacer(minLength: 0)
            if wide {
                Picker("Show", selection: $layout) {
                    ForEach(FileDiffView.Layout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    /// The host's answers, always in reach however far the page is scrolled.
    private var bar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let refusal {
                Text(refusal)
                    .appText(.supporting)
                    .foregroundStyle(StateTint.failure.style(or: .primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if asking {
                TextField("What to change, for the agent that made it", text: $note, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Spacer()
                if asking {
                    Button("Cancel") { asking = false }
                        .buttonStyle(.paper)
                    Button("Send to the Agent") { send(.requestChanges) }
                        .buttonStyle(.paperProminent)
                        .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    if approval.actions.contains(.requestChanges) {
                        Button(approval.word(for: .requestChanges) + "…") { asking = true }
                            .buttonStyle(.paper)
                    }
                    if approval.actions.contains(.deny) {
                        Button(approval.word(for: .deny)) { send(.deny) }
                            .buttonStyle(.paper)
                    }
                    if approval.actions.contains(.approve) {
                        Button(approval.word(for: .approve)) { send(.approve) }
                            .buttonStyle(.paperProminent)
                    }
                }
            }
            .disabled(busy || isOffline || (reading == nil && approval.digest != nil))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The version answered is the one read, so a change since is refused, not approved.
    private func send(_ action: Approval.Action) {
        busy = true
        refusal = nil
        Task {
            let note = action == .requestChanges ? note : nil
            refusal = await answer(action, reading?.digest ?? approval.digest, note)
            busy = false
            if refusal == nil { done() }
        }
    }

    /// A reading's lines as one hunk of the whole file, numbered from line 1 on both sides.
    static func rows(_ reading: GuardedChangeReading) -> [DiffRow] {
        LineDiff.rows(hunks: [.init(lines: reading.lines.map { line in
            let kind: DiffRow.Kind = switch line.kind {
            case .same: .context
            case .removed: .removed
            case .added: .added
            }
            return (kind, line.text)
        })])
    }
}

/// Where a Review page was, once its change is answered or gone (#1472).
struct ReviewGonePage: View {
    var body: some View {
        ContentUnavailableView("Nothing waits for an OK here", systemImage: "checkmark.shield",
                               description: Text("The change was answered, or it is no longer there."))
    }
}
