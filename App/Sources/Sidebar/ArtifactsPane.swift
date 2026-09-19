import AgentsKit
import SwiftUI

/// What the agent handed over, in one list, away from the messages it arrived in.
///
/// Only what the runtime marked: a `resource_link` or an embedded `resource`, and
/// nothing else (FR-046). No runtime installed here sends those blocks yet, so the
/// empty state below is this pane's ordinary screen rather than an edge case, and it is
/// written to read as a fact rather than as a failure.
struct ArtifactsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    let agent: Agent
    let state: AgentPaneState

    /// Derived on read, every time, and never stored. That is what makes artifacts last
    /// exactly as long as the transcript does, across restarts and for a stopped or
    /// archived agent (FR-044), and it is why the list updates on `agent/entry` with no
    /// new notification of its own (FR-041).
    private var artifacts: [Artifact] { Artifact.all(in: model.entries) }

    var body: some View {
        Group {
            if artifacts.isEmpty {
                Nothing()
            } else {
                List(artifacts) { artifact in
                    row(artifact)
                }
                .listStyle(.inset)
            }
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
                if artifact.isMissing {
                    // It stays in the list. The record that it arrived is still true
                    // (FR-045).
                    Text("no longer there")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
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

/// The pane's ordinary screen, and the one people will actually see.
///
/// Written as a statement about what will appear here, not an apology and not an error.
/// Nothing has gone wrong: the agents simply have not started handing things over yet.
private struct Nothing: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing handed over yet")
                .font(.headline)
            Text("When an agent finishes something and hands it over by name, it appears here, so you can find it again without scrolling back through the conversation.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("Files the agent merely changed are marked in Files instead.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
