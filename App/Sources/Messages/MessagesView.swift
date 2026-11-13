import AgentsKitCore
import SwiftUI

/// The list's state (#4344), kept by the model while the window is open, so a conversation's page
/// goes back to the list as it was left.
@MainActor @Observable
final class MessagesListState {
    var lists: [MessagesList.HostConversations]?
    /// A service's word (slack, email), or "" for All.
    var source = ""
    var unreadOnly = false
    /// The conversation open over the list.
    var open: MessagesList.Row?
    var asked = 0
    var loadingMore = false

    var ask: [String] { [String(asked), String(unreadOnly)] }
    var rows: [MessagesList.Row] { MessagesList.merged(lists ?? [], source: source) }
    var hasMore: Bool { lists?.contains { $0.cursor != nil } ?? false }

    func load(model: AppModel) async {
        let asked = asked
        let unread = unreadOnly
        lists = nil
        let read = await Self.read(model.messagesMachines, model: model) { _ in
            DaemonAPI.MessagesConversationsRequest(limit: 50, unread: unread ? true : nil)
        }
        // A newer Refresh wins.
        if asked == self.asked, unread == unreadOnly { lists = read }
    }

    /// The next page of each machine that has one, after its own.
    func more(model: AppModel) async {
        guard let lists, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let unread = unreadOnly
        let machines = model.messagesMachines.filter { m in lists.contains { $0.host == m.id && $0.cursor != nil } }
        let cursors = Dictionary(lists.map { ($0.host, $0.cursor) }, uniquingKeysWith: { a, _ in a })
        let got = await Self.read(machines, model: model) { host in
            DaemonAPI.MessagesConversationsRequest(cursor: cursors[host] ?? nil, limit: 50, unread: unread ? true : nil)
        }
        self.lists = lists.map { list in
            guard let next = got.first(where: { $0.host == list.host }) else { return list }
            var list = list
            list.conversations += next.conversations
            list.cursor = next.cursor
            list.errors = next.errors
            list.problem = next.problem
            return list
        }
    }

    private static func read(_ machines: [(id: MachineRef, name: String)], model: AppModel,
                             request: (MachineRef) -> DaemonAPI.MessagesConversationsRequest)
        async -> [MessagesList.HostConversations] {
        var got: [(host: MachineRef, list: DaemonAPI.MessagesConversations?, problem: String?)] = []
        await withTaskGroup(of: (MachineRef, DaemonAPI.MessagesConversations?, String?).self) { group in
            for machine in machines {
                let asked = request(machine.id)
                group.addTask {
                    do {
                        return (machine.id, try await model.messages(DaemonAPI.Method.messagesConversations, asked,
                                                                     returning: DaemonAPI.MessagesConversations.self,
                                                                     on: machine.id), nil)
                    } catch {
                        return (machine.id, nil, error.localizedDescription)
                    }
                }
            }
            for await (host, list, problem) in group { got.append((host, list, problem)) }
        }
        let read = machines.compactMap { m -> MessagesList.HostConversations? in
            guard let one = got.first(where: { $0.host == m.id }) else { return nil }
            guard let list = one.list else { return .init(host: m.id, name: m.name, problem: one.problem) }
            return .init(host: m.id, name: m.name, conversations: list.conversations, cursor: list.cursor,
                         errors: list.errors ?? [])
        }
        // The machines' own order: this Mac first, so its copy of a conversation is the one kept.
        return read
    }
}

/// Messages (#4344): the conversations of every messaging connector that follows the messaging
/// contract, on every machine, in one list, the newest first, with Source and Unread filters; a
/// conversation opens to its messages, with a reply field when its connector can send (#4345). The
/// web page's is `Web/src/views/Messages.tsx`.
struct MessagesView: View {
    @Bindable var list: MessagesListState

    var body: some View {
        Group {
            if let row = list.open {
                ConversationPage(row: row).id(row.id)
            } else {
                MessagesListPane(list: list)
            }
        }
        .navigationTitle(list.open?.conversation.title ?? MessagesList.title)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { list.open = nil } label: { Image(toolbarIcon: "chevron.left") }
                    .disabled(list.open == nil)
                    .help("Back to Messages")
            }
        }
    }
}

private struct MessagesListPane: View {
    @Environment(AppModel.self) private var model
    @Bindable var list: MessagesListState

    var body: some View {
        VStack(spacing: 0) {
            filters.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            content
        }
        .task(id: list.ask) { await list.load(model: model) }
    }

    private var filters: some View {
        HStack(spacing: 12) {
            Picker("Source", selection: $list.source) {
                Text("All").tag("")
                ForEach(MessagesList.sources(list.lists ?? []), id: \.self) { Text(ChannelLinkWords.channel($0)).tag($0) }
            }
            .fixedSize()
            Toggle("Unread", isOn: $list.unreadOnly)
                .toggleStyle(.checkbox)
            Spacer()
            Button("Refresh") { list.asked += 1 }
                .linkStyle()
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.messagesMachines.isEmpty {
            message(MessagesList.noMachine)
        } else if let lists = list.lists {
            if MessagesList.noConnector(lists), !list.unreadOnly {
                noConnector
            } else {
                let rows = list.rows
                List {
                    ForEach(MessagesList.problems(lists), id: \.self) { line in
                        Label(line, icon: "exclamationmark.triangle").foregroundStyle(.secondary)
                    }
                    if rows.isEmpty {
                        Text(list.unreadOnly ? MessagesList.noUnread : MessagesList.noConversations).foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        Button { list.open = row } label: { ConversationRow(row: row) }
                            .buttonStyle(.plain)
                    }
                    if list.hasMore {
                        Button(list.loadingMore ? "Loading…" : "More") { Task { await list.more(model: model) } }
                            .linkStyle()
                            .disabled(list.loadingMore)
                    }
                }
                .listStyle(.inset)
            }
        } else {
            // The first read: placeholder rows, as Work draws them, no spinner in the middle.
            List { WorkPlaceholderRows() }.listStyle(.inset).disabled(true)
        }
    }

    /// No connector yet: a way to the Messaging slot, in the folder's Connectors.
    private var noConnector: some View {
        VStack(spacing: 12) {
            Text(MessagesList.noConnector)
                .appText(.supporting)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let key = model.selectedFolderKey ?? model.folders.first.map({ FolderKey(host: $0.host, folder: $0.folder.folder) }) {
                Button(MessagesList.setUp) { model.sidebarItem = .folderMCPServers(key) }
                    .linkStyle()
                    .help("The folder’s Connectors, with its Messaging slot")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .appText(.supporting)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A row: the service's icon, who sent the newest message (when the service says), the conversation's title,
/// its unread count and when it last moved.
private struct ConversationRow: View {
    let row: MessagesList.Row

    var body: some View {
        let c = row.conversation
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(icon: MessagesList.symbol(c.source))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .help(ChannelLinkWords.channel(c.source))
                .accessibilityLabel(ChannelLinkWords.channel(c.source))
            if let sender = c.sender {
                Text(verbatim: MessagesList.sender(sender)).fontWeight(row.isUnread ? .semibold : .regular).lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
                    .help(sender.identity)
            }
            Text(verbatim: c.title).fontWeight(row.isUnread ? .semibold : .regular).lineLimit(1)
                .foregroundStyle(c.sender == nil ? .primary : .secondary)
            if let unread = MessagesList.unread(c) {
                Text(unread).appText(.fine).foregroundStyle(.tint)
            }
            Spacer(minLength: 8)
            if let at = c.lastActivityDate {
                Text(at, format: .relative(presentation: .named)).appText(.fine).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}

/// A conversation's messages, the newest first, each with its sender, time, text (outside content,
/// drawn as Markdown that loads nothing) and a link to the original; older pages with More. Under them, the reply
/// field (#4345), when the connector can send: the person's own reply, which says who it goes as.
private struct ConversationPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    let row: MessagesList.Row

    @State private var messages: [DaemonAPI.MessagingMessage]?
    @State private var cursor: String?
    @State private var problem: String?
    @State private var loading = false
    @State private var draft = ""
    /// The thread the reply answers in; nil: the conversation itself.
    @State private var thread: String?
    @State private var sending = false
    @State private var sendProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if let problem {
                Text(problem).foregroundStyle(.secondary).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let messages {
                List {
                    Label(MessagesList.outside, icon: "exclamationmark.shield").appText(.fine).foregroundStyle(.secondary)
                    if messages.isEmpty {
                        Text(MessagesList.noMessages).foregroundStyle(.secondary)
                    }
                    ForEach(messages) { m in
                        MessageRow(message: m, replyInThread: row.item.replyAs != nil && m.thread != nil ? { thread = m.thread } : nil)
                    }
                    if cursor != nil {
                        Button(loading ? "Loading…" : "Older") { Task { await read(more: true) } }
                            .linkStyle()
                            .disabled(loading)
                    }
                }
                .listStyle(.inset)
            } else {
                List { WorkPlaceholderRows(count: 4) }.listStyle(.inset).disabled(true)
            }
            if let replyAs = row.item.replyAs, problem == nil, messages != nil {
                Divider()
                replyField(replyAs).padding(.horizontal, 16).padding(.vertical, 8)
            }
        }
        .task { await read(more: false) }
    }

    private func replyField(_ replyAs: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if thread != nil {
                HStack(spacing: 8) {
                    Label(MessagesList.inThread, icon: "arrowshape.turn.up.left").appText(.fine).foregroundStyle(.secondary)
                    Button(MessagesList.leaveThread) { thread = nil }
                        .linkStyle()
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(MessagesList.replyPlaceholder, text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .disabled(sending)
                    .accessibilityLabel(MessagesList.reply)
                Button(sending ? MessagesList.sending : MessagesList.send) { Task { await send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(sending || MessagesList.replyText(draft) == nil)
                    .help("Send the reply (⌘↩)")
            }
            Text(MessagesList.sentAs(replyAs)).appText(.fine).foregroundStyle(.secondary)
            if let sendProblem {
                Label(sendProblem, icon: "exclamationmark.triangle").appText(.fine).foregroundStyle(.secondary)
            }
        }
    }

    private func send() async {
        guard let text = MessagesList.replyText(draft), !sending else { return }
        sending = true
        sendProblem = nil
        defer { sending = false }
        do {
            let sent = try await model.messages(
                DaemonAPI.Method.messagesReply,
                DaemonAPI.MessagesReplyRequest(server: row.item.server, folder: row.item.folder, conversation: row.conversation.id,
                                               thread: thread, text: text),
                returning: DaemonAPI.MessagesReplied.self, on: row.host)
            messages = [sent.message] + (messages ?? [])
            draft = ""
        } catch {
            sendProblem = model.describe(error)
        }
    }

    private var header: some View {
        let c = row.conversation
        return HStack(spacing: 8) {
            Image(icon: MessagesList.symbol(c.source)).foregroundStyle(.secondary)
            Text(ChannelLinkWords.channel(c.source)).foregroundStyle(.secondary)
            Text(verbatim: "▸ \(row.item.server)").appText(.fine).foregroundStyle(.secondary)
            Spacer()
            if let link = c.link, let url = URL(string: link) {
                Button("Open in \(ChannelLinkWords.channel(c.source))") { openURL(url) }
                    .linkStyle()
                    .help(link)
            }
        }
    }

    private func read(more: Bool) async {
        loading = true
        defer { loading = false }
        do {
            let got = try await model.messages(
                DaemonAPI.Method.messagesRead,
                DaemonAPI.MessagesReadRequest(server: row.item.server, folder: row.item.folder, conversation: row.conversation.id,
                                              cursor: more ? cursor : nil, limit: 50),
                returning: DaemonAPI.MessagesRead.self, on: row.host)
            messages = (more ? messages ?? [] : []) + got.messages
            cursor = got.cursor
        } catch {
            problem = error.localizedDescription
        }
    }
}

private struct MessageRow: View {
    @Environment(\.openURL) private var openURL
    let message: DaemonAPI.MessagingMessage
    /// Answer in this message's thread; nil when the conversation takes no reply, or it is in none.
    var replyInThread: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(verbatim: MessagesList.sender(message.sender)).fontWeight(.semibold).lineLimit(1)
                    .help(message.sender.identity)
                if let at = message.date {
                    Text(at, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .appText(.fine).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if let replyInThread {
                    Button(MessagesList.replyInThread, action: replyInThread)
                        .linkStyle()
                }
                if let link = message.link, let url = URL(string: link) {
                    Button("Original") { openURL(url) }
                        .linkStyle()
                        .help(link)
                }
            }
            // Outside content: Markdown with no base and no remote-image loader, so an image
            // stays its alternative text and nothing is fetched (FR-013).
            MarkdownText(markdown: message.text).textSelection(.enabled)
        }
        .padding(.vertical, 4)
    }
}

/// The sidebar's Messages row (#4934): the title, and under it in grey the unread count and what the newest
/// `message.received` woke, as the Summary and Events rows have a line ("12 unread · woke Fix login bug 4 min ago").
/// The count asks every messaging connector over MCP, so it is read on a timer, and left out while it fails;
/// the events are each machine's newest page. No machine that reads messages: no line.
struct MessagesRow: View {
    @Environment(AppModel.self) private var model
    @State private var unread: Int?
    @State private var last: MessagesList.LastConsequence?

    /// How often the line is read again.
    static let every: Duration = .seconds(60)

    var body: some View {
        let machines = model.messagesMachines
        // The time ago moves on between reads.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let line = machines.isEmpty ? nil : MessagesList.statusLine(unread: unread, last: last, now: context.date)
            VStack(alignment: .leading, spacing: 1) {
                HStack { Text(MessagesList.title).foregroundStyle(.primary); Spacer() }
                if let line {
                    Text(line).appText(.fine).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .accessibilityValue(line ?? "")
        }
        .task(id: machines.map(\.id.rawValue)) {
            while !Task.isCancelled {
                await read(machines)
                try? await Task.sleep(for: Self.every)
            }
        }
    }

    private func read(_ machines: [(id: MachineRef, name: String)]) async {
        guard !machines.isEmpty else { unread = nil; last = nil; return }
        let model = model
        var lists: [MessagesList.HostConversations] = []
        var events: [Event] = []
        await withTaskGroup(of: (MessagesList.HostConversations?, [Event]).self) { group in
            for machine in machines {
                group.addTask {
                    async let list = try? model.messages(DaemonAPI.Method.messagesConversations,
                                                         DaemonAPI.MessagesConversationsRequest(limit: 50, unread: true),
                                                         returning: DaemonAPI.MessagesConversations.self, on: machine.id)
                    async let page = try? model.client(for: machine.id).call(DaemonAPI.Method.eventsList,
                                                                              DaemonAPI.EventsListRequest(),
                                                                              returning: DaemonAPI.EventsPage.self)
                    let conversations = await list
                    return (conversations.map { .init(host: machine.id, name: machine.name, conversations: $0.conversations) },
                            await page?.events ?? [])
                }
            }
            for await (list, page) in group {
                if let list { lists.append(list) }
                events += page
            }
        }
        // This Mac first, so its copy of a conversation is the one counted, as the page keeps it.
        lists.sort { a, b in
            (machines.firstIndex { $0.id == a.host } ?? 0) < (machines.firstIndex { $0.id == b.host } ?? 0)
        }
        unread = lists.isEmpty ? nil : MessagesList.unreadTotal(lists) ?? 0
        last = MessagesList.lastConsequence(events)
    }
}
