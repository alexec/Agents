import AgentsKitCore
import SwiftUI

/// One folder in the sidebar, the row its sessions fold under: the Mac's `ProjectRow`
/// (#145, #226). As a group's heading, a grey count of its own sessions, as every group's
/// heading says it (#587); as a row, a dot when something in it is waiting on you.
struct ProjectRow: View {
    @Environment(RemoteModel.self) private var model
    let summary: DaemonAPI.ProjectSummary
    /// The name as the sidebar shows it: `server:Project` on a server.
    var label: String? = nil
    /// Folded, the row says what is under it; unfolded, the rows under it say that.
    var isFolded = true
    /// Drawn as its group's heading in the sidebar (#495, #498): the name in grey, as a
    /// group's heading is, so the sessions under it read first.
    var asHeading = false

    /// The phone's own counts, not `summary.counts`: the daemon's are made without
    /// knowing which agents have asked to be looked at. The Mac's row does the same.
    private var counts: [AgentGroup: Int] { model.counts(in: summary.key) }

    /// Exactly when something in it is under Needs you.
    private var needsPerson: Bool { (counts[.needsAttention] ?? 0) > 0 }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    // The chat project (#229) says what it is for.
                    if summary.isChat == true {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .imageScale(.small)
                            .foregroundStyle(Paper.accent)
                            .accessibilityHidden(true)
                    }
                    Text(label ?? summary.name)
                        .lineLimit(1)
                        .foregroundStyle(summary.exists && !asHeading ? .primary : .secondary)
                    if summary.project.isPinned {
                        Image(systemName: "pin.fill")
                            .imageScale(.small)
                            .foregroundStyle(Paper.accent)
                            .accessibilityHidden(true)
                    }
                }
                if !summary.exists {
                    Text("Folder is missing")
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                } else if isFolded, !asHeading, let subtitle {
                    Text(subtitle)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if asHeading {
                // How many its group lists (#587). Who needs you is in Needs You at the
                // top, so no dot.
                if ownCount > 0 {
                    Text("\(ownCount)")
                        .monospacedDigit()
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
            } else if needsPerson {
                Circle()
                    .fill(StateTint.attention.style(or: .secondary))
                    .frame(width: 7, height: 7)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// The sessions its group lists, each listed once (`SidebarSmartRow.home`).
    private var ownCount: Int { SidebarProjectFold.ownCount(summary.key, in: model.work) }

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
        if summary.isChat == true { parts.append("chat project") }
        if summary.project.isPinned { parts.append("pinned") }
        if !summary.exists { parts.append("folder is missing") }
        if asHeading {
            if ownCount > 0 { parts.append("\(ownCount)") }
        } else if let subtitle {
            parts.append(subtitle)
        }
        return parts.joined(separator: ", ")
    }
}

/// What today has cost, the Mac's row: drawn whether or not anything has been spent so
/// Spending is always there to go in by. The title alone (#587): the day's figure and
/// what is left are VoiceOver's, and near the limit the row's icon turns red.
struct SpendingRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Cost")
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(figures ?? "")
        .accessibilityHint("Opens Cost")
    }

    /// Today's cost, and what is left of a daily limit where there is one.
    private var figures: String? {
        guard let today else { return nil }
        if let state = model.costState, let left = state.dayHeadroom, let daily = state.limits.daily {
            return "\(today) today, \(left.money(in: daily.currency)) left"
        }
        return "\(today) today"
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
    @State private var adding: NewProject?

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
                Button("Add Project…") { adding = .folder(.mac) }
                    .buttonStyle(.borderedProminent)
                Button("Clone Project from Git URL…") { adding = .clone(.mac) }
                    .buttonStyle(.bordered)
            }
            .padding()
            .sheet(item: $adding) { NewProjectSheet(adding: $0) }
        }
    }
}
