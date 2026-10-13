import AgentsKitCore
import SwiftUI

/// Write It for Me (#858, layouts L10a): the runtime menu and the button, beside the field
/// the agent writes. The menu shows only when more than one runtime can write.
struct WriteItForMeButton: View {
    let runtimes: DaemonAPI.ProviderRuntimes?
    @Binding var runtime: String?
    /// Write Again, once a draft is in the field.
    var again = false
    var isDisabled = false
    let write: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let runtimes, runtimes.runtimes.count > 1 {
                Picker("Runtime", selection: $runtime) {
                    ForEach(runtimes.runtimes) { each in
                        Text(each.name).tag(Optional(each.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Button(again ? "Write Again" : "Write It for Me", action: write)
                .buttonStyle(.paper)
                .disabled(isDisabled || runtimes?.runtimes.isEmpty != false)
                .help(runtimes?.why ?? "An agent reads the server’s tools or the CLI’s help where the control plane runs, and writes this for you to read. It never sees your secrets.")
        }
    }
}

/// Where a draft stands, under the field it fills (L10b–L10d): the step line while it writes,
/// a question when it asks, and what it got once it is done.
struct ProviderDraftStatus: View {
    let update: DaemonAPI.ProviderDraftUpdate?
    /// The agent is starting: no update yet.
    let starting: Bool
    /// The person has changed what the agent wrote.
    var changed = false
    let cancel: () -> Void
    let answer: (UUID, Bool) -> Void
    let again: () -> Void

    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if starting || update.map({ !$0.ended }) == true {
                writing
            }
            if let question = update?.question {
                questionCard(question)
            }
            if let update, update.ended {
                ended(update)
            }
        }
    }

    private var writing: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(stepLine)
                .appText(.supporting).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
            Spacer(minLength: 4)
            if let cost = update?.cost {
                Text(cost).appText(.supporting).foregroundStyle(.secondary)
            }
            detailsButton
            Button(action: cancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .help("Stop writing. Nothing is kept.")
            .accessibilityLabel("Stop writing")
        }
    }

    private var stepLine: String {
        let recent = (update?.steps ?? []).suffix(2).map(\.text)
        return recent.isEmpty ? "Writing…" : "Writing… " + recent.joined(separator: " · ")
    }

    /// The question in the sheet (L10c), as the plan card is drawn (#776): an accent bar.
    private func questionCard(_ question: DaemonAPI.DraftQuestion) -> some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(StateTint.attention.color ?? .secondary)
                .frame(width: 3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(question.text)
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Spacer()
                    Button("Don’t") { answer(question.id, false) }
                        .buttonStyle(.paper)
                    Button(question.yes) { answer(question.id, true) }
                        .buttonStyle(.paperProminent)
                }
            }
        }
        .padding(12)
        .background(StateTint.attention.color?.opacity(0.07) ?? .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(question.text)
    }

    @ViewBuilder
    private func ended(_ update: DaemonAPI.ProviderDraftUpdate) -> some View {
        switch update.state {
        case "done":
            if let line = listLine(update) {
                Text(line + (changed ? " (before your change)" : ""))
                    .appText(.supporting)
                    .tinted(update.check?.passed == true ? .none : .attention)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !changed {
                Text("Written by \(update.runtimeName). Read it before you add it.")
                    .appText(.supporting).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                if let note = update.note, !note.isEmpty {
                    Text("“\(note)”")
                        .appText(.supporting).foregroundStyle(.secondary).italic()
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                detailsButton
            }
        case "failed":
            HStack(alignment: .firstTextBaseline) {
                Text(update.note ?? "It couldn’t write it.")
                    .appText(.supporting).tinted(.failure)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                detailsButton
                Button("Try Again", action: again).buttonStyle(.paper)
            }
        default:
            EmptyView()
        }
    }

    /// "✓ Listed 3: agents-devbox (running), build-box (stopped)".
    private func listLine(_ update: DaemonAPI.ProviderDraftUpdate) -> String? {
        guard let check = update.check else { return "It sent this without a check that passed." }
        guard check.passed else { return "⚠ Its last check failed: \(check.problem ?? "no reason given")." }
        let workspaces = check.workspaces ?? []
        guard !workspaces.isEmpty else { return "✓ Listed none." }
        return "✓ Listed \(workspaces.count): " + workspaces.map { "\($0.name) (\($0.state))" }.joined(separator: ", ")
    }

    private var detailsButton: some View {
        Button("Details…") { details = true }
            .buttonStyle(.borderless)
            .appText(.supporting)
            .disabled(update?.steps.isEmpty != false)
            .popover(isPresented: $details, arrowEdge: .bottom) { detailsList }
    }

    /// Every step, and when (L10b's Details…).
    private var detailsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Writing \(update?.runtimeName ?? "") · \(update?.steps.count ?? 0) steps")
                .appText(.reading).fontWeight(.semibold)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array((update?.steps ?? []).enumerated()), id: \.offset) { _, step in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(step.at.formatted(date: .omitted, time: .standard))
                                .appText(.code).foregroundStyle(.secondary)
                            Text(step.text)
                                .appText(.supporting)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 260)
            if let note = update?.note, update?.ended == true {
                Text(note).appText(.supporting).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
