import AgentsKitCore
import SwiftUI

/// One thing waiting for the person's OK in Needs You (#773): an MCP server, a workflow, a
/// plugin or a guarded file, drawn as a session's row is (#587) — the mark, the title, the
/// time and one grey line — with the same orange mark for every kind, so "needs
/// approving" reads the same whatever it is. The window and the Remote both draw it.
struct ApprovalRowLabel: View {
    let approval: Approval
    /// Which project it is in, after the title, as a smart group's rows name theirs.
    var place: String?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ApprovalMark(kind: approval.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(approval.title)
                        .appText(.supporting)
                        .lineLimit(1)
                    if let place {
                        Text(place)
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(-1)
                    }
                }
                Text("\(approval.kindWord) · \(approval.line)")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let since = approval.since { ActivityTime(date: since) }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(approval.kind == .workflowFailed ? "stopped working" : "waiting for your approval")
    }
}

/// The mark every approval row wears: a shield in the attention tint, as a workflow
/// waiting for an OK has worn (#587); a failed workflow (#989), the triangle its own row
/// wears on its project's page.
struct ApprovalMark: View {
    var kind: Approval.Kind?

    var body: some View {
        Image(systemName: kind == .workflowFailed ? "exclamationmark.triangle" : "checkmark.shield")
            .foregroundStyle(StateTint.attention.style(or: .primary))
            .frame(width: 16)
            .accessibilityHidden(true)
    }
}

/// What a waiting item is, and the choice (#773): the lines being approved (a file's diff
/// against the approved copy, an MCP server's entry, a plugin's files), what Approve and
/// Deny do, then the buttons the host offers for it. Request changes opens a note sent to
/// the agent that made the change. The client says how to read and answer, so the sheet
/// holds no model of its own.
struct ApprovalSheet: View {
    let approval: Approval
    var place: String?
    /// What it is; nil when it could not be read, which the client has said.
    let read: () async -> GuardedChangeReading?
    /// The answer, of the version read; nil when it went, or why not.
    let answer: (Approval.Action, _ digest: String?, _ note: String?) async -> String?
    var isOffline = false

    @Environment(\.dismiss) private var dismiss
    @State private var reading: GuardedChangeReading?
    @State private var loaded = false
    @State private var busy = false
    @State private var asking = false
    @State private var note = ""
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                ApprovalMark()
                VStack(alignment: .leading, spacing: 2) {
                    Text(approval.title)
                        .appText(.reading).fontWeight(.semibold)
                    Text([approval.kindWord, place].compactMap { $0 }.joined(separator: " · "))
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            }
            Text(approval.line)
                .appText(.supporting)
            Text(approval.explanation)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reading {
                Text(reading.path)
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                ScrollView {
                    GuardedDiffView(reading: reading)
                }
                .frame(maxHeight: 320)
                .fixedSize(horizontal: false, vertical: true)
            } else if !loaded {
                ProgressView().controlSize(.small)
            }
            if asking {
                TextField("What to change, for the agent that made it", text: $note, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
            }
            if let refusal {
                Text(refusal)
                    .appText(.supporting)
                    .foregroundStyle(StateTint.failure.style(or: .primary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(18)
        .frame(minWidth: 380, idealWidth: 520, maxWidth: 640, alignment: .leading)
        .task(id: approval) {
            // An archive request has nothing to read: its session is the thing.
            guard approval.kind != .archive else { loaded = true; return }
            reading = await read()
            loaded = true
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if asking {
                Button("Send to the Agent") { send(.requestChanges) }
                    .buttonStyle(.paperProminent)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } else {
                if approval.actions.contains(.requestChanges) {
                    Button(approval.word(for: .requestChanges)) { asking = true }
                        .buttonStyle(.paper)
                }
                if approval.actions.contains(.deny) {
                    Button(approval.word(for: .deny)) { send(.deny) }
                        .buttonStyle(.paper)
                }
                if approval.actions.contains(.approve) {
                    Button(approval.word(for: .approve)) { send(.approve) }
                        .buttonStyle(.paperProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .disabled(busy || isOffline || (approval.kind != .archive && reading == nil && approval.digest != nil))
    }

    /// The version answered is the one read, so a change since is refused, not approved.
    private func send(_ action: Approval.Action) {
        busy = true
        refusal = nil
        Task {
            let digest = approval.kind == .archive ? nil : (reading?.digest ?? approval.digest)
            let note = action == .requestChanges ? note : nil
            refusal = await answer(action, digest, note)
            busy = false
            if refusal == nil { dismiss() }
        }
    }
}
