import AgentsKitCore
import SwiftUI

/// One workflow, opened up — the Mac's `WorkflowPage`, on a phone: what it has done.
///
/// Why it is or isn't running, Run Now or Approve, Pin, Archive or Unarchive, and the agents it
/// has run (#142). How it is set up (the prompt, triggers, settings, labels, machines, its file)
/// and Delete are Mac + web (#2796, #2798): the Remote does not have them.
struct WorkflowPage: View {
    @Environment(RemoteModel.self) private var model
    let workflowID: Workflow.ID

    @State private var rawWorkflowText: String?
    @State private var shownRuns = Self.runsAtFirst
    /// Whether the Mac has runs past the ones shown. Archived runs are not in the
    /// phone's list until this page asks for them, so it cannot count them itself.
    @State private var moreRuns = false

    private static let runsAtFirst = 3
    private static let runsPerMore = 6

    private var summary: WorkflowSummary? {
        model.workflows.first { $0.id == workflowID }
    }

    var body: some View {
        ScrollView {
            if let summary {
                content(summary)
            } else {
                ContentUnavailableView("This workflow is no longer there",
                                       systemImage: "clock.badge.questionmark",
                                       description: Text("Its file has been removed or renamed."))
                    .padding(.top, 60)
            }
        }
        .navigationTitle(summary?.workflow.name ?? "Workflow")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .shows([.workflows])
        .refreshable { await model.catchUp() }
        .toolbar {
            if let summary {
                // Pin or Unpin (#432), beside Archive, as the Mac's page has it.
                if !summary.isArchived {
                    ToolbarItem(placement: .topBarTrailing) { PinWorkflowButton(summary: summary) }
                }
                ToolbarItem(placement: .topBarTrailing) { archiveButton(summary) }
            }
        }
        .onChange(of: workflowID) { shownRuns = Self.runsAtFirst }
        // Its runs, archived ones too, a page at a time; again when one starts.
        .task(id: RunsAsk(workflowID: workflowID, shown: shownRuns)) {
            guard let summary else { return }
            moreRuns = await model.loadRuns(of: summary.workflowID, in: summary.workflow.folder,
                                            limit: shownRuns)
        }
        .task(id: summary?.workflow) {
            guard let workflow = summary?.workflow, workflow.problem?.needsAPerson == true else {
                rawWorkflowText = nil
                return
            }
            guard case .text(let text, let isTruncated, let size, _)? = try? await model.readPage(
                ".agents/workflows/\(workflow.workflowID).md", in: workflow.folder) else { return }
            rawWorkflowText = isTruncated
                ? text + "\n\n" + FileReading.truncationNote(shown: text.utf8.count, of: size)
                : text
        }
    }

    /// The agents it started that the phone holds, newest first.
    private func content(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        return VStack(alignment: .leading, spacing: 22) {
            heading(summary)
            runButton(summary)
            // What it has done. How it is set up is Mac + web (#2798).
            status(summary)
            if workflow.problem?.needsAPerson == true { unreadableFile() }
            runs(workflow)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .readableWidth()
    }

    // MARK: The title

    /// The name and what it is, in the row's words. What is happening to it is the
    /// status card's (#142).
    private func heading(_ summary: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.workflow.name)
                .appText(.title).fontWeight(.semibold)
                .fixedSize(horizontal: false, vertical: true)
            if summary.workflow.problem == nil {
                Text(summary.workflow.summary)
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // Yours, in every folder (#2759): its rows under a folder do not say so.
            if let scope = summary.scopeSentence {
                Text(scope)
                    .appText(.fine)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Why it is or isn't running (#142)

    /// The Mac page's status card, line for line: what stops it, what it is doing, and
    /// when it next runs.
    private func status(_ summary: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Status")
            VStack(alignment: .leading, spacing: 0) {
                let lines = summary.statusLines
                ForEach(Array(lines.enumerated()), id: \.element.id) { index, line in
                    if index > 0 { Divider().padding(.leading, 42) }
                    statusRow(line)
                }
            }
            .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            // How often it may run, the Mac page's sentence under its triggers (#103).
            if let cooldown = summary.cooldownSentence(formatting: { $0.formatted(date: .omitted, time: .shortened) }) {
                note(cooldown)
            }
        }
    }

    private func statusRow(_ line: WorkflowStatusLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: line.symbol)
                .appText(.reading)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(line.text)
                    .appText(.reading)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = line.detail {
                    Text(detail)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let agentID = line.agentID {
                    NavigationLink(value: RemoteRoute.agent(agentID)) {
                        Text("Open the agent")
                    }
                    .appText(.fine)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(line.tint.style(or: .primary))
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    /// Run now, full width under the title where a thumb finds it, or Unarchive when
    /// it is put away. Offered even on a workflow that cannot fire on its own: a refusal
    /// says why, which is better than nothing happening.
    @ViewBuilder
    private func runButton(_ summary: WorkflowSummary) -> some View {
        Group {
            if summary.isArchived {
                Button { Task { await model.setWorkflowArchived(summary, false) } } label: {
                    Text("Unarchive").frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 12) {
                    if summary.isUnapproved {
                        // As on the Mac: Run now comes back once it is approved, and one
                        // waiting its turn has neither; the status card says why (#132).
                        if summary.canBeApproved {
                            Button { Task { await model.approveWorkflow(summary) } } label: {
                                Text("Approve").frame(maxWidth: .infinity)
                            }
                        }
                        // Not on this host, without archiving it everywhere (#391).
                        if summary.canBeDenied {
                            Button { Task { await model.denyWorkflow(summary) } } label: {
                                Text("Deny on This Machine").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.paper)
                        }
                    } else if summary.runsHere {
                        Button { Task { await model.runWorkflow(summary) } } label: {
                            Text(summary.isRunning ? "Running…" : "Run now").frame(maxWidth: .infinity)
                        }
                        .disabled(summary.isRunning)
                    }
                    // Under Run now, which still works with it off (#100).
                    Toggle("Enabled", isOn: Binding(
                        get: { summary.isEnabled },
                        set: { on in Task { await model.setWorkflowEnabled(summary, on) } }))
                        .appText(.reading)
                    // Its runs still go under Needs You, and send no notifications (#2003).
                    if model.canMute(summary) {
                        Toggle(MuteWords.mute, isOn: Binding(
                            get: { summary.workflow.isMuted },
                            set: { on in Task { await model.setWorkflowMuted(summary, on) } }))
                            .appText(.reading)
                    }
                    // What Mute does (#2086): its runs still go under Needs You and in the badge.
                    if model.canMute(summary) {
                        Text(MuteWords.workflowHelp(muted: summary.workflow.isMuted))
                            .appText(.fine)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // They write the workflow's file (#125), the Mac page's words.
                    Text(summary.switchesSentence)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.paperProminent)
        .disabled(model.isStale)
    }

    /// Archive, in the bar, where a chat keeps its own. It goes back to the folder, as
    /// the Mac's does: putting a thing away is one gesture wherever it is.
    @ViewBuilder
    private func archiveButton(_ summary: WorkflowSummary) -> some View {
        if !summary.isArchived {
            Button {
                Task {
                    await model.setWorkflowArchived(summary, true)
                    model.openWorkflow = nil
                }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .disabled(model.isStale)
        }
    }

    private func unreadableFile() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("The file is below")
            if let rawWorkflowText {
                Text(rawWorkflowText)
                    .appText(.code)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .paperRaised(in: RoundedRectangle(cornerRadius: 18))
            } else {
                note("The workflow file could not be read from the machine.")
            }
        }
    }

    // MARK: What it has run

    /// The agents it started, newest first, as the folder page draws them — each a
    /// tap from its conversation, and back comes here. Three to begin with.
    private func runs(_ workflow: Workflow) -> some View {
        let started = model.work.workflowRuns(workflow.workflowID, in: workflow.folder)
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Recent runs")
            if started.isEmpty {
                note("Nothing has run yet.")
            }
            ForEach(started.prefix(shownRuns)) { agent in
                AgentCard(agent: agent)
            }
            if started.count > shownRuns || moreRuns {
                Button("Show more") {
                    shownRuns += Self.runsPerMore
                }
                .appText(.reading)
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .appText(.reading).fontWeight(.semibold)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// When a workflow page fetches its runs: opened, paged, or a run arrived.
private struct RunsAsk: Equatable {
    var workflowID: Workflow.ID
    var shown: Int
}
