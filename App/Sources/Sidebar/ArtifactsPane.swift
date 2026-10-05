import AgentsKitCore
import SwiftUI

/// Everything named in the conversation, in one list, away from the messages it
/// arrived in: what you attached to a prompt, and what an agent handed back.
///
/// Only what is named as a thing rather than said: a `resource_link` or an embedded
/// `resource`, and nothing else (FR-046). Both directions count, because a file is
/// worth finding again whichever way it went, and an attachment you sent is the one
/// entry this list is sure to have — no runtime installed here hands anything over
/// yet, so until one does, this pane is a record of what you gave it.
struct ArtifactsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    let agent: Agent
    let state: AgentPaneState

    /// Derived from the transcript and never stored anywhere else. That is what makes
    /// artifacts last exactly as long as the transcript does, across restarts and for
    /// a stopped or archived agent (FR-044), and it is why the list updates on
    /// `agent/entry` with no new notification of its own (FR-041).
    ///
    /// Folded when the page changes rather than on every redraw: the page grows
    /// several times a second while an agent talks, and each fold asked the disk
    /// whether every file was still there.
    @State private var artifacts: [Artifact] = []
    @State private var missing: Set<String> = []
    /// How far into `entries` has been folded, and the first entry that fold started
    /// from. A page put in front, or one trimmed, starts again (#285).
    @State private var scanned = 0
    @State private var anchor: UUID?
    /// Artifacts already asked about, so a new entry does not stat every earlier one.
    @State private var checked: Set<String> = []
    /// A server directory's names, listed once per parent. Unknown when the list
    /// failed or was cut short: that is not "gone".
    @State private var parentLists: [String: ParentNames] = [:]

    private enum ParentNames {
        case names(Set<String>)
        case unknown
    }

    var body: some View {
        Group {
            if artifacts.isEmpty {
                Nothing()
            } else {
                List(artifacts) { artifact in
                    row(artifact)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        // Only while shown, and once more on being shown: hidden, each new entry was a
        // pass over the chat and a look at the disk for nobody (#213).
        .task(id: frame.pane == .artifacts ? model.entries.count : -1) {
            if frame.pane == .artifacts { await fold() }
        }
    }

    /// The artifacts in entries not yet folded, then whether each new file is still
    /// there. A file on a server is asked of that host, once per directory (#285).
    private func fold() async {
        let entries = model.entries
        let grewAtEnd = anchor != nil && entries.first?.id == anchor && entries.count >= scanned
        if grewAtEnd {
            let found = Artifact.all(in: entries.dropFirst(scanned))
            var known = Set(artifacts.map(\.id))
            let added = found.filter { known.insert($0.id).inserted }
            if !added.isEmpty {
                artifacts = (added + artifacts).sorted { $0.arrivedAt > $1.arrivedAt }
            }
        } else {
            artifacts = Artifact.all(in: entries)
            missing = missing.filter { id in artifacts.contains { $0.id == id } }
        }
        scanned = entries.count
        anchor = entries.first?.id
        for artifact in artifacts where !checked.contains(artifact.id) {
            await markMissing(artifact)
            if Task.isCancelled { return }
        }
    }

    private func markMissing(_ artifact: Artifact) async {
        guard checked.insert(artifact.id).inserted else { return }
        if model.isOnThisMac(agent.host) {
            if artifact.isMissing(onThisMac: true) { missing.insert(artifact.id) }
            return
        }
        guard case .file(let url) = artifact.destination else { return }
        let parent = url.deletingLastPathComponent()
        let known: ParentNames
        if let cached = parentLists[parent.path] {
            known = cached
        } else {
            // A newer entry cancels this ask. Remembering it as unknown would never
            // look again, so a cancelled ask is left unchecked (#285).
            guard let listed = await parentNames(parent) else {
                checked.remove(artifact.id)
                return
            }
            parentLists[parent.path] = listed
            known = listed
        }
        // A name the host's listing did not have. A truncated or failed list stays
        // `.unknown`, which is not "gone" (`Artifact.isAbsent`).
        if case .names(let names) = known, !names.contains(url.lastPathComponent) {
            missing.insert(artifact.id)
        }
    }

    /// Nil when the ask was cancelled. A failed or truncated list is `.unknown`.
    private func parentNames(_ parent: URL) async -> ParentNames? {
        do {
            let listing = try await model.serverFiles(agent.host).list(agentID: agent.id, folder: parent)
            guard !Task.isCancelled else { return nil }
            guard !listing.isTruncated else { return .unknown }
            return .names(Set(listing.entries.map(\.name)))
        } catch {
            return Task.isCancelled ? nil : .unknown
        }
    }

    private func row(_ artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: symbol(for: artifact))
                    .foregroundStyle(.secondary)
                Text(artifact.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            HStack(spacing: 6) {
                Text(artifact.arrivedAt, style: .relative)
                if let mimeType = artifact.mimeType {
                    Text(mimeType)
                }
                if let size = artifact.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
                if missing.contains(artifact.id) {
                    // It stays in the list. The record that it arrived is still true
                    // (FR-045). Red, not orange: a missing artifact is the same news
                    // as a missing folder, and nobody is being asked anything.
                    Text("no longer there")
                        .tinted(.failure)
                }
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { open(artifact) }
        .contextMenu {
            Button("Show the message it came from") { showMessage(artifact) }
        }
    }

    private func symbol(for artifact: Artifact) -> String {
        switch artifact.destination {
        case .web: return "globe"
        case .inPlace: return "doc.text"
        case .file: return "doc"
        case .nowhere: return "questionmark.circle"
        }
    }

    private func open(_ artifact: Artifact) {
        switch artifact.destination {
        case .file(let url):
            // Opened where it can be read, which is the files pane (FR-042).
            state.folder = url.deletingLastPathComponent()
            state.openFile = url
            state.openLine = nil
            frame.pane = .files
        case .web(let url):
            state.browserURL = url
            frame.pane = .browser
        case .inPlace, .nowhere:
            break
        }
    }

    private func showMessage(_ artifact: Artifact) {
        // Getting back to where it came from is half of what this pane is for (FR-042).
        model.focusEntry(artifact.entryID)
    }
}

/// The pane before anything has been named, which for a fresh agent is every time.
///
/// Written as a statement about what will appear here, not an apology and not an error.
/// Nothing has gone wrong: nothing has been passed either way yet.
private struct Nothing: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .appText(.title)
                .foregroundStyle(.tertiary)
            Text("Nothing exchanged yet")
                .appText(.reading).fontWeight(.semibold)
            Text("A file you attach to a prompt, or one an agent hands back by name, appears here, so you can find it again without scrolling back through the conversation.")
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Files the agent merely changed are marked in Files instead.")
                .appText(.fine)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
