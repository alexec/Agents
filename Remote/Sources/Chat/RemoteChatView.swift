import AgentsKitCore
import SwiftUI

/// The conversation: what the agent has said and done, and the question it is stuck on.
///
/// The third level, reached by a push with a back button, never a third column. It
/// opens at the end and asks backwards as the reader scrolls up, because an hour of
/// transcript is not something to fetch over a mobile connection to show the last
/// paragraph of.
struct RemoteChatView: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// How much of the foot of the screen the prompt area and any card above it cover.
    @State private var formHeight: CGFloat = 0
    /// The subagent whose steps are open, by its id (057).
    @State private var subagentOnScreen: String?
    @Environment(\.openURL) private var openURL
    /// The open chat's views (#187), torn down when another chat opens.
    @State private var views = AppViewStore()
    /// Open File… is up over the chat (#415).
    @State private var searchingFiles = false
    /// Find in Chat is up over the chat (#1532).
    @State private var finding = false
    /// The Prompts list is up over the chat (#1658).
    @State private var showingPrompts = false
    /// How wide the conversation is, so a pull can be told from the right edge (#1560).
    @State private var conversationWidth: CGFloat = 0
    /// How near the right edge a pull starts to bring in the panes: about the width of
    /// the system's own left-edge Back (#1560).
    private static let edgePull: CGFloat = 24
    /// Set in a scene of its own (#888): this session, not the selection.
    @Environment(\.poppedChat) private var popped
    /// The folder of the scene this is in, when it is a folder's own (#1089): Archive
    /// leaves the chat there too, back to the folder's list (#2090).
    @Environment(\.sceneFolder) private var sceneFolder

    private var agent: Agent? { popped.map { model.work.agent($0.id) } ?? model.selectedAgent }
    /// This chat's page of the transcript: its scene's own, or the main scene's.
    private var page: AgentsModel { model.page(popped) }

    var body: some View {
        Group {
            if let agent {
                // The conversation with its panes beside it or over it (034).
                PaneHost(agent: agent) { conversation }
            } else if popped?.looked ?? (model.lookedForSelection == model.selection) {
                // A session that went while it was open: not an empty chat to type into,
                // which is New Session's (#2652), as on the Mac (#2651).
                SessionDeletedPage(next: sizeClass == .compact ? .goBack : .pickAnother)
            } else {
                // Not looked for yet: on its way, not gone.
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // What its prompt bar reads: the runtime's capabilities, the cost limit, the
        // sandbox default and what the agent holds (#175).
        .shows([.runtimes, .costs, .sandbox, .leases])
        .overlay { fileSearch }
        // ⌘P with a keyboard attached, as on the Mac (#415). A button no one sees, so
        // the key is there whatever has focus.
        .background {
            Button("Open File…") { searchingFiles = true }
                .keyboardShortcut("p")
                .disabled(agent == nil)
                .opacity(0)
                .accessibilityHidden(true)
            // ⌘F finds in the chat with a keyboard attached, as on the Mac (#1532).
            Button("Find in Chat") { finding = true }
                .keyboardShortcut("f")
                .disabled(!findsInChat)
                .opacity(0)
                .accessibilityHidden(true)
            // ⇧⌘P, the Mac's Prompts (#1658).
            Button("Prompts") { showingPrompts = true }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(agent == nil || popped != nil)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .onChange(of: agent?.id) { searchingFiles = false }
    }

    /// Open File… (#415): the session's files by name, found on its host. The one chosen
    /// opens where it belongs — a Markdown file on the Page, anything else in Files —
    /// ready to type in.
    @ViewBuilder
    private var fileSearch: some View {
        if searchingFiles, let agent {
            let model = model
            FileSearch(place: agent.cwd.lastPathComponent,
                       search: { await model.mentions($0, for: agent.id) },
                       choose: { file in
                           searchingFiles = false
                           model.panes.state(for: agent.id).open(file: file.url, line: nil)
                       },
                       dismiss: { searchingFiles = false })
        }
    }

    private var conversation: some View {
        // The Mac's shape (033): the conversation runs the full height and the prompt
        // area floats over its foot. A question is the last thing in the conversation,
        // not over it (#723). The conversation is told how tall the prompt is so the
        // last thing said can still be scrolled clear of it.
        ZStack(alignment: .bottom) {
            if let agent {
                let page = page
                ChatTranscript(agent: agent,
                               items: page.transcriptItems,
                               stored: page.turns,
                               hasMore: page.hasMoreOfTheConversation,
                               entryCount: page.entries.count + page.turns.count,
                               isComingBack: model.isComingBack(agent),
                               lastEntryAt: page.lastEntryAt,
                               loadFailure: page.transcriptLoadFailure,
                               settleKey: model.chatID(popped),
                               loadEarlier: { [popped] in
                                   if let popped { await model.loadEarlier(of: popped) } else { await model.loadEarlier() }
                               },
                               bottomInset: formHeight,
                               cards: cards,
                               scrollToEndToken: popped?.scrollToEndToken ?? model.scrollToEndToken,
                               focusedEntry: popped == nil ? model.focusedEntry : nil,
                               focusedIndex: popped == nil ? model.focusedIndex : nil,
                               clearFocus: { [model] in
                                   model.focusedEntry = nil
                                   model.focusedIndex = nil
                               },
                               // The conversation is the only thing that knows how tall
                               // it is, and the page it asks for next should be sized to
                               // that (SC-007).
                               onHeight: { model.measure(transcriptHeight: $0) },
                               onFollowing: { page.isFollowingEnd = $0 })
                    // Voice mode speaks a turn's reply when it ends (#2322).
                    .voiceModeObserves(agent, items: page.transcriptItems,
                                       question: model.work.elicitation(for: agent.id),
                                       permission: model.work.permission(for: agent.id),
                                       approve: { await model.answer($0, optionID: $1) }) {
                        await model.answer($0, action: .accept, content: $1)
                    }
            }
            form
        }
        // Find in Chat (#1532): over the top of the chat, which scrolls on under it.
        .safeAreaInset(edge: .top, spacing: 0) {
            if finding, let agent {
                ChatFindBar(agentID: agent.id,
                            search: { [model] text in await model.find(text, in: agent.id) },
                            go: { [model] match in await model.reveal(match) },
                            close: { finding = false })
                    .background(Paper.ground)
            }
        }
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { conversationWidth = $0 }
        // A pull from the right edge brings what was exchanged in from that side, as the
        // Mac's two-finger swipe does. Only from the edge: a swipe across the chat is a
        // scroll, a little sideways or not (#1560). Left to right stays the system's Back.
        .simultaneousGesture(
            DragGesture(minimumDistance: 30)
                .onEnded { drag in
                    guard let agent, drag.startLocation.x >= conversationWidth - Self.edgePull,
                          drag.translation.width < -80,
                          abs(drag.translation.width) > abs(drag.translation.height) * 2 else { return }
                    model.panes.state(for: agent.id).show(.exchanged)
                }
        )
        .environment(\.chatActions, actions)
        .environment(\.orgSandboxSetBy, model.sandboxSettings.setBy)
        // A file a message links to is on the Mac: it opens in Files, as a file a tool
        // call touched does (#548). Links to the web are the system's.
        .environment(\.openURL, OpenURLAction { [actions] url in
            guard url.isFileURL else { return .systemAction }
            actions.open(ToolCallLocation(path: url.path(percentEncoded: false)))
            return .handled
        })
        .environment(\.appViewStore, views)
        .environment(\.appViewActions, agent.map(appViewActions))
        // A view full screen is drawn in the chat's place, as on the Mac (#187).
        .overlay {
            if let id = views.fullscreen, let host = views.existing(id) {
                AppViewFullscreen(host: host)
            }
        }
        .onChange(of: agent?.id) { views.tearDownAll() }
        // A view read when the link dropped may never be answered: read it again (#978).
        .onChange(of: model.isConnected) { if model.isConnected { views.reconnected() } }
        .onDisappear { views.tearDownAll() }
        .navigationTitle(agent?.title ?? "Agent")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                StaleBanner()
                // A server's agent whose host has gone: which, and since when (#239).
                if let agent { HostOfflineStrip(host: agent.host) }
                // A volume that host writes to low on space (#1329).
                if let agent { HostDiskStrip(host: agent.host) }
                // Its folder gone (#119): which, and the ways on, before anything is typed.
                if let agent, agent.missingFolder != nil, agent.state != .archived {
                    RemoteMissingFolderStrip(agent: agent)
                }
                // Its account gone or refused by the organisation (#999): why, and Continue in New.
                if let agent, agent.missingFolder == nil, let reason = model.accountMoveReason(agent) {
                    RemoteAccountMoveStrip(agent: agent, reason: reason)
                }
                // A session failed when its allowance ran out (#1859): Continue when it is back, or Cancel.
                if let agent, ContinueWhenBackWords.offers(agent) || agent.continueWhenBack != nil,
                   model.host(agent.host, has: Capability.chatContinueWhenBack1) {
                    RemoteContinueWhenBackStrip(agent: agent)
                        .background(Paper.ground)
                }
                // Blocked (039): what it waits on, as the row says it (#341). Carry on is
                // the toolbar's, in the ··· menu on a phone (#981).
                if let agent, model.isBlocked(agent) {
                    WaitLines(lines: model.blockLines(agent))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Paper.ground)
                }
                // Under the banner, not over it: when the Mac has gone quiet, what
                // the agent last said it would do is the less urgent of the two.
                if let agent { CurrentPlanStrip(agent: agent) }
                // The agent asked to be looked at while something was being typed: said
                // here, to be opened when the person chooses (034 FR-005). The main scene's.
                if popped == nil, let wanted = model.fileTheAgentWants { OfferedFileStrip(file: wanted) }
            }
        }
        .sheet(isPresented: Binding(get: { model.fileOnScreen != nil },
                                    set: { if !$0 { model.fileOnScreen = nil } })) {
            // A look-aside, not a level. On the Mac this is a pane beside the
            // conversation; a sheet is what that is on a screen with one column.
            NavigationStack {
                if let path = model.fileOnScreen {
                    ChangesView(path: path)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { model.fileOnScreen = nil }
                            }
                        }
                }
            }
            .paperSheet()
        }
        // The person's prompts (#1658): one goes to it in the chat, as Find does.
        .sheet(isPresented: $showingPrompts) {
            if let agent {
                PromptsList(agent: agent, page: page,
                            go: { [model] prompt in
                                model.focusedIndex = nil
                                model.focusedEntry = prompt.id
                            },
                            branch: branchFrom.map { branch in { branch($0.id, $0.text) } },
                            loadEarlier: { [model] in await model.loadEarlier() },
                            close: { showingPrompts = false },
                            branchNeedsUpdate: branchNeedsUpdate)
            }
        }
        .sheet(isPresented: Binding(get: { subagentOnScreen != nil },
                                    set: { if !$0 { subagentOnScreen = nil } })) {
            NavigationStack {
                if let id = subagentOnScreen,
                   let item = agent?.background.first(where: { $0.id == id }) {
                    SubagentStepsView(item: item, entries: page.entries)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { subagentOnScreen = nil }
                            }
                        }
                }
            }
            .paperSheet()
        }
        // The agent asking to be looked at. An event, so it opens the moment it
        // arrives and is taken off the model in the same breath.
        .onChange(of: model.fileTheAgentWants) { _, wanted in
            if popped == nil, wanted != nil { model.openFileTheAgentWants() }
        }
        .toolbar {
            // Stop is the prompt's own button while the agent works, as on the Mac;
            // Pin and Archive are in the bar where there is room, as the Mac's toolbar
            // has them, and in the ··· menu on a phone (#586).
            // Blocked (039): the card's Carry on, where the chat's own controls are. On a
            // phone, one ··· button and nothing else: Carry on and the panes are in it (#981).
            if let agent, sizeClass == .regular, model.isBlocked(agent) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.carryOn(agent.id) }
                    } label: {
                        Label(AgentsModel.carryOnLabel, systemImage: "play.circle")
                    }
                    .disabled(model.isStale(agent))
                    .accessibilityHint(AgentsModel.carryOnHelp(for: agent))
                }
            }
            if let agent, sizeClass == .regular {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if agent.state == .archived {
                        UnarchiveAgentButton(agent: agent)
                    } else {
                        PinAgentButton(agent: agent)
                        // A scene of its own stays, saying it is archived (#888).
                        ArchiveAgentButton(agent: agent, leavesChat: popped == nil || sceneFolder != nil)
                    }
                }
            }
            if let agent, sizeClass == .regular {
                ToolbarItem(placement: .topBarTrailing) {
                    // The Mac's side panes: Page, Files, Terminal, Exchanged (034). One
                    // tap opens the last one used; the switch at its top reaches the rest.
                    Button {
                        let state = model.panes.state(for: agent.id)
                        if state.pane == nil { state.show(state.defaultPane) } else { state.pane = nil }
                    } label: {
                        Label("Panes", systemImage: "sidebar.right")
                    }
                    .accessibilityHint("Shows the page, files and terminal for this agent")
                }
            }
            if let agent {
                ToolbarItem(placement: .topBarTrailing) {
                    ChatMenu(agent: agent, find: popped == nil ? { finding = true } : nil,
                             findsOnHost: findsInChat,
                             prompts: popped == nil ? { showingPrompts = true } : nil) { searchingFiles = true }
                }
            }
        }
    }

    /// What waits on the person, then the agent's wait on events, at the end of the
    /// conversation, as on the Mac (#723, #1995). None when nothing waits.
    ///
    /// The question card keeps the phone's own shape — its options stacked and what it
    /// covers shown in full — because a row of buttons at a large text size is a row of
    /// truncated words.
    private var cards: [WaitingCard] {
        guard let agent else { return [] }
        var cards: [WaitingCard] = []
        for request in model.work.permissions(for: agent.id) {
            cards.append(WaitingCard(id: request.id.uuidString) {
                // A fresh sheet per question, so a tap in flight on the last one is not
                // carried over to the next.
                PermissionSheet(request: request)
                    .id(request.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        // A change its agent made to the folder's own files waits the same way (#531).
        for change in model.work.guardedChanges(askedIn: agent.id) {
            cards.append(WaitingCard(id: "guarded:" + change.id) {
                GuardedChangeQuestion(change: change, key: FolderKey(host: agent.host, folder: agent.folderPath))
                    .chatColumn()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        // A form waits the same way a permission does, never hidden behind one (#243),
        // as on the Mac.
        if let form = model.work.elicitation(for: agent.id) {
            cards.append(WaitingCard(id: form.id.uuidString) {
                ElicitationSheet(request: form)
                    .id(form.id)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        // An ask to be archived waits the same way, last when asked at once, as on the
        // Mac (#827).
        if agent.asksToArchive {
            cards.append(WaitingCard(id: "archive:" + agent.id.uuidString) {
                ArchiveRequestCard(agent: agent,
                                   approve: { await model.archive(agent.id) },
                                   keep: { await model.keepSession(agent) },
                                   isDisabled: model.isStale(agent) || model.acting(agent.id) != nil)
                    .chatColumn()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        // The agent's wait on events, under the questions, as on the Mac (#1995), with Show
        // in Events: Activity's Events page, Waiting now at its top (#2083). Not in a scene of
        // its own, which has no Activity.
        if agent.eventWait?.isOpen == true, let status = model.work.waitStatus(of: agent) {
            let open: (() -> Void)? = popped == nil ? { [model] in model.sidebarItem = .events } : nil
            cards.append(WaitingCard(id: "wait:" + agent.id.uuidString) {
                WaitCard(status: status, eventWait: agent.eventWait,
                         isLineWait: agent.eventWait?.lineResource != nil,
                         open: open,
                         stop: { await model.cancelWait(of: agent.id) },
                         isDisabled: model.isStale(agent))
                    .chatColumn()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        return cards
    }

    /// The prompt, floating over the foot of the conversation in its column, as on the
    /// Mac (FR-018). It stays under a question rather than giving way to it, so what
    /// would be typed past it is in view.
    private var form: some View {
        VStack(spacing: 12) {
            if let agent {
                // Kept on an archived chat, as on the window and the page (#242): what is
                // typed there brings it back ("Say what next, and this comes back").
                PromptBar(agent: agent, isQuestionUp: isQuestionUp)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
        .animation(.snappy(duration: 0.2), value: isQuestionUp)
    }

    private var isQuestionUp: Bool {
        guard let agent else { return false }
        return !model.work.permissions(for: agent.id).isEmpty || model.work.elicitation(for: agent.id) != nil
    }

    /// What the shared chat rows mean on a phone. A file a tool call touched opens as it
    /// is now, in Files at the line the call named, with what the agent did one tap from
    /// there (034 FR-014). A Mac too old to read files for the phone gets 033's sheet of
    /// the change instead.
    /// Run a command from a reply in the session's Terminal pane (#1533), where the Mac can
    /// give one.
    private var runCommand: (@MainActor (String) -> Void)? {
        guard !model.macLacksPanes, let agent else { return nil }
        return { [model] command in
            let state = model.panes.state(for: agent.id)
            state.frontShellZero()
            state.show(.terminal)
            Task {
                await model.runCommand(command, in: agent.id)
                // The pane, shown just now, asks the Mac for its shells, and the answer may
                // have come before shell 0 was open again.
                state.frontShellZero()
            }
        }
    }

    private var tellAgent: (@MainActor (String) -> Void)? {
        guard let agent else { return nil }
        return { [model] command in Task { await model.tellAgent(about: command, in: agent.id) } }
    }

    private var actions: ChatActions {
        let agentID = agent?.id
        // Activity ▸ Resources (#116), as the Mac opens its Resources page (#2344). Not in a
        // scene of its own, which has no Activity: there the line is words alone (#2447).
        var openLease: (@MainActor (ResourceName) -> Void)?
        if popped == nil { openLease = { [model] _ in model.sidebarItem = .resources } }
        return ChatActions(
            open: { [model] location in
                guard !model.macLacksPanes, let agentID else {
                    model.fileOnScreen = location.path
                    return
                }
                model.panes.state(for: agentID).open(file: URL(filePath: location.path), line: location.line)
            },
            terminalOutput: { [model, popped] id in
                popped.map { $0.work.terminalOutput[id] ?? "" } ?? model.terminalOutput(id)
            },
            unqueue: { [model] prompt, agentID in await model.unqueue(prompt, from: agentID) },
            editQueued: { [model] prompt, text, agentID in await model.editQueued(prompt, text: text, of: agentID) },
            canEditQueued: { [model] agentID in model.agent(agentID, has: Capability.agentsEditQueued1) },
            quote: { [model, agent] words in model.offeredQuote = PromptOffer(agentID: agent?.id, words: words) },
            branchFrom: branchFrom,
            branchNeedsUpdate: branchNeedsUpdate,
            runCommand: runCommand,
            tellAgent: tellAgent,
            sendNow: { [model] prompt, agentID in await model.sendNow(prompt, to: agentID) },
            canSendNow: { [model] runtimeID in model.canSteer(runtimeID) },
            acting: { [model] agentID in model.acting(agentID) },
            // Show in Changes under an edit (#242), at that file in the new pane (#245).
            showEdit: { [model] diff, _ in
                guard let agentID else { model.fileOnScreen = diff.path; return }
                let panes = model.panes.state(for: agentID)
                panes.changesPath = diff.path
                panes.show(.changes)
            },
            // A subagent's own steps, in a sheet: the Mac's Background pane, on a phone
            // (057, frame E).
            subagentSteps: { id in subagentOnScreen = id },
            turnEntries: { [model] agentID, range in await model.turnEntries(agentID, range) },
            reloadTranscript: { [model, popped] in
                if let popped { await model.loadTranscript(of: popped) } else { await model.loadTranscript() }
            },
            continueWithoutSandbox: sandboxAnswer(carryOn: true),
            keepStopped: sandboxAnswer(carryOn: false),
            waitingSandbox: waitingSandbox,
            kept: { [model] agentID in model.kept(for: agentID) },
            dropKept: { [model] in await model.dropKept($0) },
            retryKept: { [model] in await model.retryKept($0) },
            hostName: { [model] in model.hostName($0) },
            // A card in the chat opens its file in Files, as the agent's call did (#836).
            showFile: { [model] file in model.openShownFile(file) },
            readFile: { [model] path in
                guard let agentID else { return nil }
                return try? await model.files.read(agentID: agentID, path: path)
            },
            picture: { [model] file in
                guard let agentID,
                      let image = await model.pictures.image(agentID: agentID, url: file.url) else { return nil }
                return Image(uiImage: image)
            },
            leaseStatus: { [model] agentID in model.work.leaseStatus(of: agentID) },
            openLease: openLease)
    }

    /// What a view in the chat may ask of the phone (#187): the Mac it is on, the person's
    /// own send, the browser, and a new agent's page.
    private func appViewActions(_ agent: Agent) -> AppViewActions {
        AppViewActions(
            agentID: agent.id,
            call: { [model] method, params in try await model.viewCall(method, params) },
            send: { [model] text in await model.send(text, to: agent.id) },
            openLink: { [openURL] url in openURL(url) },
            pin: { [model] view in await model.pinView(view, in: agent.folderPath) },
            // The folder's New session page, filled in (#834).
            startAgent: { [model] start in
                model.offerStart(start, in: FolderKey(host: agent.host, folder: agent.folderPath))
            },
            // The session on a pull request's branch (#837), asked under the view first.
            recipient: { [model] message in
                model.recipient(of: message, in: FolderKey(host: agent.host, folder: agent.folderPath))
            },
            sendTo: { [model] id, text in await model.send(text, to: id) })
    }

    /// Find in Chat (#1532): not in a popped-out chat, nor on a host too old to find (#1748).
    private var findsInChat: Bool {
        agent != nil && popped == nil && model.agent(agent?.id, has: Capability.agentsFind1)
    }

    /// Branch from Here (#1658), on a prompt in the chat or in the Prompts list: as Branch,
    /// not on an archived session.
    private var branchFrom: (@MainActor (UUID, String) -> Void)? {
        // Not on a host too old to branch (#1748).
        guard let agent, agent.state != .archived, model.host(agent.host, has: Capability.chatBranch1) else { return nil }
        return { [model] entryID, text in Task { await model.branch(from: entryID, of: agent.id, text: text) } }
    }

    /// Branch from Here kept, greyed, on a host too old to branch (#1866).
    private var branchNeedsUpdate: Bool {
        guard let agent, agent.state != .archived else { return false }
        return !model.host(agent.host, has: Capability.chatBranch1)
    }

    /// The open agent's sandbox card, while it waits (064).
    private var waitingSandbox: SandboxFailureRecord? {
        agent?.pendingSandboxFailure
    }

    private func sandboxAnswer(carryOn: Bool) -> (@MainActor () async -> Void)? {
        guard waitingSandbox != nil, let id = agent?.id else { return nil }
        let model = model
        return { await model.answerSandbox(id, carryOn: carryOn) }
    }
}

/// The rarer things to do with this agent, and on a phone, where the bar has no room
/// for them, Pin and Archive (#586), Carry on and the panes (#981).
private struct ChatMenu: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.poppedChat) private var popped
    /// The folder of the scene this is in, when it is a folder's own (#1089): Archive
    /// leaves the chat there too, back to the folder's list (#2090).
    @Environment(\.sceneFolder) private var sceneFolder
    @Environment(\.horizontalSizeClass) private var sizeClass
    let agent: Agent
    /// Find in Chat (#1532), over the chat. Nil in a scene of its own.
    var find: (() -> Void)? = nil
    /// Whether the chat's host can find: on one too old (#1748) the item is greyed, with
    /// the update help, not left out (#1867).
    var findsOnHost = true
    /// The Prompts list (#1658), over the chat. Nil in a scene of its own.
    var prompts: (() -> Void)? = nil
    /// Open File… (#415), over the chat.
    let openFile: () -> Void
    /// Whether the chat draws the agent's thoughts (#1725): View ▸ Show Thoughts on the Mac,
    /// this menu here, which has no View menu (#2383).
    @AppStorage(ChatThoughts.showsKey, store: WindowDefaults.store) private var showsThoughts = ChatThoughts.showsAtFirst

    var body: some View {
        Menu {
            // Blocked (039): first, on a phone. The card in the chat keeps its own (#981).
            if sizeClass != .regular, model.isBlocked(agent) {
                Button(AgentsModel.carryOnLabel, systemImage: "play.circle") {
                    Task { await model.carryOn(agent.id) }
                }
                .disabled(model.isStale(agent))
                .accessibilityHint(AgentsModel.carryOnHelp(for: agent))
                Divider()
            }
            if let find {
                // A menu draws a label's second line under the item: the update help.
                Button(action: find) {
                    Label {
                        Text("Find in Chat")
                        if !findsOnHost { Text(UpdateWords.hostNeedsUpdate) }
                    } icon: {
                        Image(systemName: "text.magnifyingglass")
                    }
                }
                .disabled(!findsOnHost)
            }
            if let prompts {
                Button("Prompts", systemImage: "list.number", action: prompts)
            }
            Button("Open File…", systemImage: "magnifyingglass", action: openFile)
            Button(ChatThoughts.menuTitle(showsThoughts: showsThoughts), systemImage: "brain") { showsThoughts.toggle() }
                .accessibilityHint(ChatThoughts.menuHelp)
            // On a phone, the panes one item each, in place of the bar's Panes button
            // (#981): the Page once there is one, and only what the Mac can give.
            if sizeClass != .regular, !model.macLacksPanes {
                let state = model.panes.state(for: agent.id)
                if state.pagePath != nil {
                    Button("Page", systemImage: "doc.richtext") { state.show(.page) }
                }
                Button("Files", systemImage: "folder") { state.show(.files) }
                Button("Terminal", systemImage: "terminal") { state.show(.terminal) }
                Button("Simulator", systemImage: "iphone") { state.show(.simulator) }
            }
            Button("Exchanged", systemImage: "doc") { model.panes.state(for: agent.id).show(.exchanged) }
            // The main scene's chat, in a scene of its own (#888).
            if popped == nil { OpenInNewWindowButton(agent: agent) }
            if agent.state != .archived {
                // As the Mac's Session menu has them (#342, #751).
                RenameAgentButton(agent: agent)
                MuteAgentButton(agent: agent)
                BranchAgentButton(agent: agent)
                if sizeClass != .regular {
                    Divider()
                    PinAgentButton(agent: agent)
                    ArchiveAgentButton(agent: agent, leavesChat: popped == nil || sceneFolder != nil)
                }
            } else {
                Divider()
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    Task { await model.unarchive(agent.id) }
                }
                .disabled(model.isStale(agent))
            }
        } label: {
            Label("Actions", systemImage: "ellipsis.circle")
        }
    }
}

/// How full the agent's context is, and what it has cost. The size is as reported and
/// never estimated, so a runtime that sends none shows no ring; the cost is always
/// shown, falling back to zero, so the figure never disappears mid-session.
struct ContextMeter: View {
    @Environment(RemoteModel.self) private var model
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            if let usage = agent.usage, let fraction = usage.fraction {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke((usage.isCloseToFull ? StateTint.failure : .none)
                                    .style(or: .secondary),
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 12, height: 12)
                .accessibilityLabel(label(usage))
            }
            Text(cost)
                .monospacedDigit()
                .foregroundStyle((isCloseToItsLimit ? StateTint.failure : .none)
                                    .style(or: .secondary))
        }
        .appText(.fine)
    }

    /// The running total and what is left of the limit, matching the window exactly.
    ///
    /// Until the first turn ends there is no total, so the figure the runtime quotes
    /// mid-turn stands in — still its own number — and before anything has been
    /// priced at all, a plain zero. A runtime that reports no price is named as
    /// unmeasured rather than shown as within a limit it cannot be held to.
    private var cost: String {
        if agent.costIsUnmeasured { return agent.tokenFigure(under: model.costLimits) ?? "Not measured" }
        let spent = Cost.total(of: agent.costToDate)
            ?? (agent.usage?.cost?.amount ?? 0)
                .money(in: agent.usage?.cost?.currency ?? "USD")
        // On an org account the figure is the runtime's list price, and says so (#999).
        guard let ceiling = agent.ceiling(under: model.costLimits) else { return agent.priced(spent) }
        return agent.priced("\(spent) of \(ceiling.amount.formatted(.currency(code: ceiling.currency)))")
    }

    /// The app's existing threshold for a nearly full context, not a second number.
    private var isCloseToItsLimit: Bool {
        if agent.isCloseToTokenLimit(under: model.costLimits) { return true }
        guard let ceiling = agent.ceiling(under: model.costLimits), ceiling.amount > 0,
              !agent.costIsUnmeasured else { return false }
        return ((agent.costToDate[ceiling.currency] ?? 0) / ceiling.amount)
            >= Decimal(Usage.closeToFull)
    }

    private func label(_ usage: Usage) -> String {
        let tokens = "\(usage.used.formatted()) of \(usage.size.formatted()) tokens"
        return usage.isCloseToFull ? "Context nearly full — \(tokens)" : tokens
    }
}

/// "Wants you to see plan.md", with Open and not now (034 FR-005).
///
/// The agent's request, kept on the chat rather than taking the screen: somebody typing
/// is not somebody to interrupt, and the file will still be there when they are done.
private struct OfferedFileStrip: View {
    @Environment(RemoteModel.self) private var model
    let file: ShownFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ShownFile.isMarkdown(file.url) ? "doc.richtext" : "doc.text")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Wants you to see \(Text(file.name).fontWeight(.semibold))")
                .appText(.supporting)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Open") { model.openOfferedFile() }
                .buttonStyle(.paper)
            Button {
                model.dismissOfferedFile()
            } label: {
                Label("Not now", systemImage: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paperWell(in: Rectangle())
    }
}
