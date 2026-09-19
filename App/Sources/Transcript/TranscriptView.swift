import AgentsKit
import SwiftUI

/// What an agent has said and done, as it happens.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    let agent: Agent

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.transcriptHasMore {
                            Button("Show earlier") { Task { await model.loadEarlier() } }
                                .buttonStyle(.link)
                                .padding(.bottom, 4)
                        }
                        // Chunks of one message are joined for reading; the record
                        // keeps every one of them.
                        ForEach(TranscriptEntry.coalesced(model.entries)) { entry in
                            EntryView(entry: entry).id(entry.id)
                        }
                        Color.clear.frame(height: 1).id(bottom)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: model.entries.count) {
                    withAnimation(.easeOut(duration: 0.15)) { scroller.scrollTo(bottom, anchor: .bottom) }
                }
            }
            if let request = model.permissionForSelection {
                Divider()
                PermissionView(request: request)
            }
            Divider()
            Composer(agent: agent)
        }
        .navigationTitle(agent.title ?? "Agent")
        .navigationSubtitle(agent.cwd.path(percentEncoded: false))
        .toolbar {
            ToolbarItemGroup {
                if agent.state.holdsRuntime {
                    Button { Task { await model.stop(agent.id) } } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
                if agent.state == .archived {
                    Button { Task { await model.unarchive(agent.id) } } label: {
                        Label("Bring back", systemImage: "tray.and.arrow.up")
                    }
                } else {
                    Button { Task { await model.archive(agent.id) } } label: {
                        Label("Archive", systemImage: "archivebox")
                    }
                }
            }
        }
    }

    private var bottom: String { "bottom" }
}

private struct EntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .userMessage(let text):
            Bubble(text: text, role: "You", tint: .accentColor)

        case .agentMessage(_, let text):
            Text(text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .agentThought(_, let text):
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

        case .toolCall(let call), .toolCallUpdate(let call):
            Label {
                HStack(spacing: 6) {
                    Text(call.title)
                    if let status = call.status {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "wrench.and.screwdriver")
            }
            .font(.callout)

        case .plan:
            Label("Made a plan", systemImage: "list.bullet.rectangle")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .permissionAsked(let request):
            Label("Asked: \(request.toolCall.title)", systemImage: "hand.raised")
                .font(.callout)
                .foregroundStyle(.orange)

        case .permissionAnswered(let optionID, let name):
            Label("You chose \(name ?? optionID)", systemImage: "checkmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .optionChanged(let id, let value):
            Label("\(id) is now \(value.stringValue ?? "changed")", systemImage: "slider.horizontal.3")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .stateChanged(let state, let reason):
            StateChangeLine(state: state, reason: reason)

        // The gaps in an agent's life, said plainly: the runtime starting, a session
        // picked back up, a conversation the runtime could not give back.
        case .runtimeNote(let text):
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 2)
        }
    }
}

private struct Bubble: View {
    let text: String
    let role: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(role).font(.caption.weight(.medium)).foregroundStyle(tint)
            Text(text).textSelection(.enabled)
        }
        .padding(10)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct StateChangeLine: View {
    let state: AgentState
    let reason: EndedReason?

    var body: some View {
        HStack(spacing: 6) {
            StateDot(state: state)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var text: String {
        switch state {
        case .running: return "Working"
        case .waitingOnUser: return "Waiting on you"
        case .finished: return "Finished"
        case .stopped:
            switch reason {
            case .cancelled: return "You stopped it"
            case .processDied: return "The runtime crashed"
            case .daemonGone: return "Stopped when the daemon did"
            case .maxTokens: return "Ran out of room"
            case .maxTurnRequests: return "Hit its limit"
            case .refusal: return "Refused to carry on"
            case .unrecognised: return "Stopped for a reason we do not know"
            case .endTurn, nil: return "Stopped"
            }
        case .archived: return "Archived"
        }
    }
}
