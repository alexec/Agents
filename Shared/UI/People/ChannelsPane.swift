import AgentsKitCore
import SwiftUI

/// Control plane ▸ Channels (#1762, spec 736 US7, FR-037): the link requests waiting for
/// this person, and the channel identities linked to them (an admin's: everyone's), each
/// with Remove. A message from an identity that is not linked starts nothing.
///
/// One view for the Mac's Settings pane and the Remote's Settings page (the web page's is
/// `Web/src/views/ChannelLinks.tsx`).
struct ChannelsPane: View {
    /// The control plane, or nil while it cannot be reached.
    let control: DaemonClient?
    let people: PeopleState

    @State private var links: [DaemonAPI.ChannelLink]?
    @State private var problem: String?
    @State private var removing: DaemonAPI.ChannelLink?

    private struct Load: Hashable {
        var reachable: Bool
        var revision: Int
    }

    var body: some View {
        Form {
            if let problem {
                Section {
                    Text(problem).appText(.supporting).tinted(.failure)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .paperListRow()
            }
            let waiting = people.openLinks()
            if !waiting.isEmpty {
                Section("Waiting") {
                    ForEach(waiting) { request in
                        ChannelLinkCard(request: request, people: people.linkPeople,
                                        isAnswering: people.answering.contains(request.request),
                                        answer: { approve, to in Task { await answer(request, approve: approve, to: to) } })
                    }
                }
                .paperListRow()
            }
            if let links {
                Section {
                    if links.isEmpty {
                        Text(ChannelLinkWords.none).appText(.supporting).foregroundStyle(.secondary)
                    }
                    ForEach(links) { link in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ChannelLinkWords.linkTitle(link)).appText(.reading)
                                Text(ChannelLinkWords.linkDetail(link, you: people.you?.id))
                                    .appText(.fine).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove…", role: .destructive) { removing = link }
                                .buttonStyle(.borderless)
                        }
                    }
                } footer: {
                    Text(ChannelLinkWords.foot).appText(.fine).foregroundStyle(.secondary)
                }
                .paperListRow()
            } else if problem == nil {
                Text("Loading…").appText(.supporting).foregroundStyle(.secondary).paperListRow()
            }
        }
        .paperForm()
        .task(id: Load(reachable: control != nil, revision: people.linksRevision)) {
            while !(await load()), !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
            }
        }
        .refreshable { await load() }
        .confirmationDialog(removing.map(ChannelLinkWords.removeTitle) ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { link in
            Button("Unlink", role: .destructive) { Task { await remove(link) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(ChannelLinkWords.removeMessage)
        }
    }

    /// False when the control plane did not answer at all, so it is worth asking again.
    @discardableResult
    private func load() async -> Bool {
        guard let control else {
            problem = "The control plane can’t be reached."
            return true
        }
        do {
            links = try await control.call(DaemonAPI.Method.linksList, DaemonAPI.Empty(),
                                           returning: [DaemonAPI.ChannelLink].self)
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
            return error is JSONRPCError
        }
        return true
    }

    private func answer(_ request: DaemonAPI.ChannelLinkRequest, approve: Bool, to: String?) async {
        problem = await people.answerLink(request, approve: approve, to: to, on: control)
        await load()
    }

    private func remove(_ link: DaemonAPI.ChannelLink) async {
        guard let control else { return }
        do {
            _ = try await control.call(DaemonAPI.Method.linksRemove,
                                       DaemonAPI.ChannelLinkRemove(channel: link.channel, identity: link.identity))
            problem = nil
        } catch {
            problem = PeopleWords.refusal(error)
        }
        let said = problem
        await load()
        if let said { problem = said }
    }
}
