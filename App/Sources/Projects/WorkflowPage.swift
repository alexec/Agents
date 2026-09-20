import AgentsKit
import SwiftUI

/// One workflow, opened up.
///
/// The reason this page exists is the prompt. An agent can write a workflow into a
/// project without anybody's approval — that is what `manage_workflows` is for — and
/// until there was somewhere to read one, the prompt was the single part of a standing
/// arrangement that nobody could see without leaving the app for an editor. Everything
/// else here was already on the row; the prompt was nowhere.
///
/// Nothing on this page edits the file's triggers or its prompt. Those are the
/// author's, and an app that quietly rewrote the body of a file in somebody's
/// repository would be a worse thing than one that made you open an editor. What can
/// be changed from here is how much the workflow is allowed to do.
///
/// Every workflow opens, including the ones that cannot run: archived, over a ceiling,
/// waiting on a trigger this version does not know, and unreadable. The unreadable one
/// is the most important of them — it is the one most likely to need looking at, and a
/// row you cannot open is a row that can only tell you that something is wrong.
struct WorkflowPage: View {
    @Environment(AppModel.self) private var model
    /// `Workflow.id`, not the workflow itself: the file on disk is the truth, and
    /// holding a copy would leave this page showing what the file used to say.
    let workflowID: Workflow.ID

    /// The file's own text, read only when the workflow cannot be parsed.
    @State private var rawText: String?

    private var summary: WorkflowSummary? {
        model.workflows(in: model.selectedProject).first { $0.id == workflowID }
    }

    var body: some View {
        ScrollView {
            if let summary {
                content(summary)
            } else {
                // The file went while it was open — deleted, renamed, or its project
                // closed. Saying so and going back beats a page about a workflow that
                // is not there, which a reader would take for a failure of the app.
                ContentUnavailableView("This workflow is no longer there",
                                       systemImage: "clock.badge.questionmark",
                                       description: Text("Its file has been removed or renamed."))
                    .padding(.top, 60)
            }
        }
        .navigationTitle(summary?.workflow.name ?? "Workflow")
        // Only once it has actually gone, and not while the list is still being loaded
        // — going back during the first draw would take the reader out of a page they
        // had only just opened.
        .onChange(of: summary == nil) { _, gone in
            guard gone, !model.workflows(in: model.selectedProject).isEmpty else { return }
            model.openWorkflow = nil
        }
    }

    @ViewBuilder
    private func content(_ summary: WorkflowSummary) -> some View {
        let workflow = summary.workflow
        VStack(alignment: .leading, spacing: 22) {
            heading(summary)
            if let problem = workflow.problem {
                broken(problem, workflow: workflow)
            }
            prompt(workflow)
            settingsNote(workflow)
            file(workflow)
            actions(summary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // The column the transcript, the prompt bar and the project page all use, so
        // this reads as another page of the same document rather than a panel.
        .chatColumn()
        .padding(.top, 28)
        .padding(.bottom, 40)
    }

    /// The name, what it is, and what is happening to it — the row's three lines, in
    /// the row's words.
    ///
    /// Deliberately the same sentence as the row: this page is the row opened up, not
    /// a second description of the same workflow that could come to disagree with it.
    private func heading(_ summary: WorkflowSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(summary.workflow.name)
                .font(.largeTitle.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            // Not when the file is broken. `Workflow.summary` falls back to the
            // problem's own sentence then, and the red line below says the same thing
            // better and next to the file it is about — twice is a stutter, and the
            // grey copy is the one carrying less.
            if summary.workflow.problem == nil {
                Text(summary.workflow.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let happening = happening(summary) {
                HStack(spacing: 4) {
                    Text(happening)
                    if let agentID = ranAgentID(summary) {
                        Text("·")
                        // The one thing here that goes anywhere, because it is the only
                        // thing with somewhere to go.
                        Button {
                            model.openWorkflow = nil
                            model.selection = agentID
                        } label: {
                            HStack(spacing: 2) {
                                Text("Open the agent it started")
                                Image(systemName: "arrow.right")
                            }
                        }
                        .buttonStyle(.link)
                    }
                }
                .font(.callout)
                .foregroundStyle((summary.needsAPerson ? StateTint.attention : .none).style(or: .secondary))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the file could not say, and the file itself.
    ///
    /// The raw text is here because the problem alone is not enough to act on: a
    /// person told their metadata block is never closed still has to go and look, and
    /// the thing they need to look at is a dozen lines long and already in hand.
    @ViewBuilder
    private func broken(_ problem: WorkflowProblem, workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(problem.message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .tinted(problem.needsAPerson ? .failure : .none)
                .fixedSize(horizontal: false, vertical: true)
            if let rawText {
                block(rawText)
            }
        }
        .task(id: workflow) { rawText = try? String(contentsOf: url(workflow), encoding: .utf8) }
    }

    /// The prompt, whole, exactly as it will be sent.
    ///
    /// Selectable and not editable. Monospaced because it is a thing that will be sent
    /// verbatim, and because the difference between two spaces and one can matter to
    /// what an agent does with it.
    @ViewBuilder
    private func prompt(_ workflow: Workflow) -> some View {
        if !workflow.prompt.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("The prompt")
                block(workflow.prompt)
            }
        }
    }

    /// What its `agent:` mode means for the settings — including for the mode where
    /// they do not apply at all.
    ///
    /// The controls themselves arrive with the next story. What is here now is the
    /// sentence they will sit under, because it is true whether or not there is a
    /// control to explain: a `triggering` workflow resumes an agent that is already
    /// running and never applies a mode, which is the other half of the row leaving
    /// the settings clause out of its summary.
    @ViewBuilder
    private func settingsNote(_ workflow: Workflow) -> some View {
        switch workflow.mode {
        case .triggering:
            note("This workflow resumes the agent that triggered it, so a permission mode, runtime or model in its file does not apply.")
        case .standing:
            if !workflow.settings.isEmpty {
                note("Applied when its standing agent is started, and again if it has to be replaced.")
            }
        case .new:
            EmptyView()
        }
    }

    /// Where the file is, and the way to it.
    private func file(_ workflow: Workflow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("The file")
            HStack(spacing: 8) {
                Text(url(workflow).path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url(workflow)])
                }
                .buttonStyle(.glass)
                .font(.callout)
            }
        }
    }

    /// Run it, and put it away or bring it back.
    ///
    /// Words rather than the row's icons: there is one of each here, so the reason the
    /// row uses symbols — that they repeat down a page and two words each would be the
    /// loudest thing on it — does not apply.
    private func actions(_ summary: WorkflowSummary) -> some View {
        HStack(spacing: 10) {
            if summary.isArchived {
                Button("Restore") { Task { await model.setWorkflowArchived(summary, false) } }
                    .buttonStyle(.glassProminent)
            } else {
                // Offered even on a workflow that cannot fire on its own. Being able to
                // try one is what makes writing one worth doing, and a refusal says why
                // rather than nothing happening.
                Button(summary.isRunning ? "Running…" : "Run now") {
                    Task { await model.runWorkflow(summary) }
                }
                .buttonStyle(.glassProminent)
                .disabled(summary.isRunning)
                Button("Archive") { Task { await model.setWorkflowArchived(summary, true) } }
                    .buttonStyle(.glass)
            }
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func block(_ text: String) -> some View {
        Text(text)
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func url(_ workflow: Workflow) -> URL {
        WorkflowFile.url(for: workflow.workflowID, in: workflow.folder)
    }

    /// When it next runs and what happened last, as one sentence. The row's third line,
    /// which is where a refusal becomes visible at all.
    private func happening(_ summary: WorkflowSummary) -> String? {
        var parts: [String] = []
        if summary.isArchived {
            parts.append("Archived — it will not run until it is restored")
        } else if let limit = summary.overLimit {
            parts.append("\(limit.sentence). \(limit.remedy)")
        } else if let next = summary.nextFireAt {
            parts.append("Next \(next.formatted(.relative(presentation: .named)))")
        }
        if let outcome = summary.lastOutcome {
            let when = outcome.at.formatted(.relative(presentation: .named))
            switch outcome {
            case .ran: parts.append("Ran \(when)")
            case .refused: parts.append(outcome.summary)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func ranAgentID(_ summary: WorkflowSummary) -> UUID? {
        if case .ran(let agentID, _) = summary.lastOutcome { return agentID }
        return nil
    }
}
