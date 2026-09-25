import AgentsKitCore
import SwiftUI

/// A document named in the conversation, read as paper rather than as source.
///
/// The Mac draws this in the Exchanged pane of its inspector (007). An iPad has no
/// inspector, so the same two surfaces — the list of what was exchanged, and the
/// document itself — are reached from the conversation's menu and pushed.
///
/// Read only, structurally: no save, no export, no share sheet. FR-020b asks for the
/// reading half and SC-014 asks that it be read-only because there is no other screen,
/// not because a flag says so.
///
/// `PageMetrics` is not used here. It lives in `AgentsKit`, which the Remote does not
/// link, and its measure ramps against a pane's width — 280 to 380 points — which is a
/// Mac inspector's problem and not a full iPad screen's. `readableWidth()` is this
/// app's own answer to the same question and the two agree on what they are for: a
/// line no longer than the eye can find its way back along.
struct DocumentView: View {
    let artifact: Artifact

    var body: some View {
        ScrollView(.vertical) {
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .readableWidth()
        }
        // The same step the Mac's document view uses, so the two read alike and
        // Dynamic Type still moves both (FR-037). New York until the type scale became
        // the whole app's; a document is read at the app's reading size now.
        .appText(.reading)
        .textSelection(.enabled)
        .navigationTitle(artifact.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
    }

    @ViewBuilder
    private var content: some View {
        switch artifact.destination {
        case .inPlace:
            // It brought its own text. Through the same renderer the conversation
            // uses, so it inherits that renderer's limits rather than a second set.
            MarkdownText(markdown: artifact.text ?? "")
        case .web(let url):
            Elsewhere(name: artifact.name,
                      detail: "It is on the web.",
                      link: url)
        case .file:
            // A path, not bytes. The protocol hands a client no way to read a file on
            // the Mac, and inventing one is not this view's business — see ChangesView.
            Elsewhere(name: artifact.name,
                      detail: "It is a file on your Mac. Open it there.",
                      link: nil)
        case .nowhere:
            Elsewhere(name: artifact.name,
                      detail: "The agent did not say where it is.",
                      link: nil)
        }
    }
}

/// A document that is not here. Said plainly, in the sans face, because it is the
/// app talking and not the document.
private struct Elsewhere: View {
    let name: String
    let detail: String
    let link: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).appText(.reading).fontWeight(.semibold)
            Text(detail).appText(.supporting).foregroundStyle(.secondary)
            if let link {
                Link(link.absoluteString, destination: link)
                    .appText(.fine)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Everything named in the conversation, in one list, away from the messages it
/// arrived in: what was attached to a prompt, and what an agent handed back.
///
/// Derived on read from the transcript, exactly as the Mac's pane derives it, so it
/// lasts as long as the transcript does and needs no notification of its own. The
/// iPad holds a page of transcript rather than all of it, so this is what was
/// exchanged *in what has been read* — said at the foot rather than left to be
/// discovered.
struct ArtifactsList: View {
    @Environment(RemoteModel.self) private var model

    private var artifacts: [Artifact] { Artifact.all(in: model.entries) }

    var body: some View {
        Group {
            if artifacts.isEmpty {
                ContentUnavailableView("Nothing exchanged",
                                       systemImage: "doc",
                                       description: Text("A file attached to a prompt, or one an agent "
                                                         + "hands back by name, shows up here."))
            } else {
                List {
                    ForEach(artifacts) { artifact in
                        if let file = liveFile(artifact) {
                            // A file in the agent's folders opens as it is now, on the Page
                            // or in Files, not as the conversation carried it (034 FR-027).
                            Button {
                                if let agentID = model.selection {
                                    model.panes.state(for: agentID).open(file: file, line: nil)
                                }
                            } label: {
                                row(artifact)
                            }
                            .buttonStyle(.plain)
                            .paperListRow()
                        } else {
                            NavigationLink {
                                DocumentView(artifact: artifact)
                            } label: {
                                row(artifact)
                            }
                            .paperListRow()
                        }
                    }
                    if model.hasMoreBefore {
                        Text("Only what is in the part of the conversation read so far.")
                            .appText(.fine)
                            .foregroundStyle(.tertiary)
                            .paperListRow()
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Exchanged")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
    }

    /// The file an entry names, when the Mac can read it for this agent. Judged by path
    /// here, because the phone has no disk to resolve it against; the Mac holds the real
    /// boundary on every read.
    private func liveFile(_ artifact: Artifact) -> URL? {
        guard !model.macLacksPanes, let agent = model.selectedAgent,
              case .file(let url) = artifact.destination else { return nil }
        let path = url.standardizedFileURL.path
        let inside = agent.folderScope.folders.contains { folder in
            let root = folder.standardizedFileURL.path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        return inside ? url : nil
    }

    private func row(_ artifact: Artifact) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(artifact.name)
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Text(artifact.arrivedAt, style: .relative)
                if let mimeType = artifact.mimeType { Text(mimeType) }
                if let size = artifact.size {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                }
            }
            .appText(.fine)
            .foregroundStyle(.secondary)
        }
    }
}
