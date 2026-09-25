import AgentsKit
import SwiftUI

/// One of the person's open pull requests (038 US1).
///
/// Two lines, in the page's one kind of card. The first says what state it is in, with
/// checks and review in columns of their own so a list of them reads down as well as
/// across. The second says where it is checked out and what babysitting last did.
///
/// Grey, all of it, except babysitting having stopped, which is the one thing here that
/// waits for the person (wireframes §4). A failing check is the pull request's state,
/// not the app's, so it is not the app's red; an approval is not an agent vouching for
/// its work, so it is not the app's green.
struct PullRequestRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let pull: PullRequest
    let folder: URL
    @Binding var selection: UUID?

    private var key: AppModel.PullRequestKey { .init(folder: folder, number: pull.number) }

    var body: some View {
        // One card. Its first line is the button that opens the pull request on GitHub
        // (FR-005); its second line sits beside that button rather than inside it,
        // because a button's label is one element to accessibility, and the worktree
        // link, Check out and Resume must each be reachable on their own.
        VStack(alignment: .leading, spacing: 4) {
            Button { openURL(pull.url) } label: {
                firstLine
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(pull.url.absoluteString)
            .accessibilityLabel("#\(pull.number) \(pull.title), open on GitHub")
            secondLine
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .paperRow()
    }

    // MARK: What state it is in

    private var firstLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("#\(pull.number)")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()
            // The title takes what is left; the columns after it are fixed, so the
            // states line up down the list.
            Text(pull.title)
                .appText(.reading).fontWeight(.semibold)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
            if pull.isDraft {
                Text("Draft")
                    .appText(.fine)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(.tertiary))
                    .fixedSize()
            }
            if pull.conflicts == .conflicting {
                Text("⚠ conflicts").fixedSize()
                    .appText(.fine)
                    .foregroundStyle(.secondary)
            }
            Group {
                Text(checks).frame(width: 70, alignment: .leading)
                Text(review).frame(width: 136, alignment: .leading)
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            Image(systemName: "arrow.up.right")
                .appText(.fine)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
    }

    private var checks: String {
        switch pull.checks {
        case .failing: return "✕ checks"
        case .passing: return "✓ checks"
        case .running: return "◌ checks"
        case .none: return ""
        }
    }

    private var review: String {
        switch pull.review {
        case .changesRequested: return "● changes requested"
        case .approved: return "✓ approved"
        case .commented: return "◦ commented"
        case .none: return ""
        }
    }

    // MARK: Where, and what babysitting did

    private var secondLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if model.checkingOut.contains(key) {
                Text("Checking out \(pull.headBranch)…")
            } else if let worktree = pull.worktree {
                where_(worktree)
                babysitting
            } else {
                // A failure stays, with its reason, beside the button to try again.
                if let failure = model.checkoutFailures[key] {
                    Text("Couldn't check out: \(failure)")
                        .lineLimit(2)
                } else {
                    Text("Not checked out here")
                }
                Button(model.checkoutFailures[key] == nil ? "Check out into a worktree" : "Try again") {
                    Task { await model.checkOut(pull.number, in: folder) }
                }
                .buttonStyle(.paper)
                .padding(.leading, 6)
            }
        }
        .appText(.fine)
        .foregroundStyle(.secondary)
    }

    /// The worktree's name, leading to the agent working there when there is one
    /// (FR-006).
    @ViewBuilder
    private func where_(_ worktree: PullRequestWorktree) -> some View {
        if let agent = agentIn(worktree) {
            Button(worktree.name) { selection = agent }
                .buttonStyle(.link)
                .help(worktree.root.path(percentEncoded: false))
        } else {
            Text(worktree.name)
                .help(worktree.root.path(percentEncoded: false))
        }
    }

    private func agentIn(_ worktree: PullRequestWorktree) -> UUID? {
        let root = worktree.root.standardizedFileURL.path
        return model.agents
            .filter { $0.state != .archived && $0.cwd.standardizedFileURL.path.hasPrefix(root) }
            .max { $0.lastActivityAt < $1.lastActivityAt }?.id
    }

    /// The last of: running now, ran, refused, stopped (FR-019, FR-023).
    @ViewBuilder
    private var babysitting: some View {
        let status = pull.babysitting
        if status.isStopped {
            Text("·")
            Text("Babysitting stopped after \(status.consecutiveRuns) tries in a row")
                .fontWeight(.semibold)
                .foregroundStyle(StateTint.attention.style(or: .secondary))
            Button("Resume") {}
                .buttonStyle(.paper)
                .disabled(true)
                .padding(.leading, 6)
        } else if status.isRunning {
            Text("·")
            Text("Babysitting now")
        } else if let outcome = status.lastRun {
            Text("·")
            switch outcome {
            case .ran(let agentID, let at):
                Button {
                    selection = agentID
                } label: {
                    HStack(spacing: 2) {
                        Text("Babysat \(at.formatted(.relative(presentation: .named)))")
                        Image(systemName: "arrow.right")
                    }
                }
                .buttonStyle(.link)
                if let said = model.agents.first(where: { $0.id == agentID })?.report?.message {
                    Text("·")
                    Text(said).lineLimit(1).truncationMode(.tail)
                }
            case .refused(let refusal, _, _):
                Text("Did not run — \(refusal.rowMessage)")
            }
        }
    }
}
