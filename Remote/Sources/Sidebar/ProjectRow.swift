import AgentsKitCore
import SwiftUI

/// One folder in the sidebar, the row its sessions fold under: the Mac's `ProjectRow`
/// (#145, #226). The dot is the whole reason to look at this list: something in here is
/// waiting on you, folded or not.
struct ProjectRow: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary
    /// The name as the sidebar shows it: `server:Project` on a server.
    var label: String? = nil
    /// Folded, the row says what is under it; unfolded, the rows under it say that.
    var isFolded = true

    /// The phone's own counts, not `summary.counts`: the daemon's are made without
    /// knowing which agents have asked to be looked at. The Mac's row does the same.
    private var counts: [AgentGroup: Int] { model.counts(in: summary.key) }

    /// Exactly when something in it is under Needs you.
    private var needsPerson: Bool { (counts[.needsAttention] ?? 0) > 0 }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label ?? summary.name)
                    .lineLimit(1)
                    .foregroundStyle(summary.exists ? .primary : .secondary)
                if !summary.exists {
                    Text("Folder is missing")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if isFolded, let subtitle {
                    Text(subtitle)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if needsPerson {
                Circle()
                    .fill(StateTint.attention.style(or: .secondary))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// What is going on in there, in the Mac row's words and order: urgency first, and
    /// only ever two facts.
    private var subtitle: String? {
        let unread = model.work.unreadCount(in: summary.key)
        if needsPerson {
            return unread > 0 ? "Needs you · \(unread) unread" : "Needs you"
        }
        let working = counts[.running] ?? 0
        var parts: [String] = []
        if working > 0 { parts.append("\(working) working") }
        if unread > 0 { parts.append("\(unread) unread") }
        if parts.isEmpty {
            let complete = counts[.finished] ?? 0
            let stopped = counts[.stopped] ?? 0
            if complete > 0 { parts.append("\(complete) complete") }
            if stopped > 0 { parts.append("\(stopped) stopped") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Said in words, because a coloured dot is not something VoiceOver can read.
    private var accessibilityLabel: String {
        var parts = [label ?? summary.name]
        if !summary.exists { parts.append("folder is missing") }
        if let subtitle { parts.append(subtitle) }
        return parts.joined(separator: ", ")
    }
}

/// What today has cost, the Mac's row: drawn whether or not anything has been spent so
/// Spending is always there to go in by.
struct SpendingRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(today == nil ? "Spending" : "Today")
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                if let today {
                    Text(today).monospacedDigit()
                }
                if let state = model.costState, let left = state.dayHeadroom,
                   let daily = state.limits.daily {
                    Text("\(left.money(in: daily.currency)) left")
                }
            }
            .appText(.fine)
            .foregroundStyle((model.costState?.dayIsCloseToFull == true ? StateTint.failure : .none)
                                .style(or: .secondary))
        }
        .accessibilityHint("Opens Spending")
    }

    private var today: String? {
        model.costState.flatMap {
            Cost.total(of: $0.today.merging(model.serversToday, uniquingKeysWith: +))
        }
    }
}

/// The first second of the app's life, over a connection with seconds in it.
///
/// Says which of the two things is happening rather than spinning at the user: still
/// asking, or asked and told nothing.
struct Waiting: View {
    @Environment(RemoteModel.self) private var model
    @State private var pairingAgain = false
    @State private var folder = ""
    @State private var gitURL = ""
    @State private var problem: String?
    @State private var adding = false

    var body: some View {
        if model.needsPairing {
            PairingView()
        } else if model.isStale {
            ContentUnavailableView {
                Label("Can't reach your Mac", systemImage: "wifi.slash")
            } description: {
                Text("It needs to be awake and on a network. "
                     + "This screen fills in as soon as it answers.")
            } actions: {
                // A device the Mac has forgotten is only turned away at home, not told
                // why, so the way back is offered here too.
                Button("Pair Again…") { pairingAgain = true }
            }
            .sheet(isPresented: $pairingAgain) { PairingView() }
        } else {
            VStack(spacing: 12) {
                Text("No projects yet").appText(.title)
                Text("Add a folder on your Mac or clone a Git repository to get started.")
                    .appText(.supporting).foregroundStyle(.secondary).multilineTextAlignment(.center)
                TextField("Folder path, such as ~/src/project", text: $folder)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Add Folder…") {
                    adding = true
                    Task { problem = await model.addProject(folder: folder); adding = false }
                }
                .buttonStyle(.borderedProminent).disabled(folder.isEmpty || adding)
                TextField("HTTPS or SSH Git URL", text: $gitURL)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                Button("Clone Git URL…") {
                    adding = true
                    Task { problem = await model.cloneProject(url: gitURL); adding = false }
                }
                .buttonStyle(.bordered).disabled(gitURL.isEmpty || adding)
                if let problem { Text(problem).appText(.fine).tinted(.failure) }
            }
            .padding()
        }
    }
}
