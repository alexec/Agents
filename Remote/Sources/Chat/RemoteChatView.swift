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
    /// The folder's own shell (#418), in the ··· menu (#2808). Nil in a scene of its own.
    @Environment(\.openFolderTerminal) private var openFolderTerminal
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow

    private var agent: Agent? { popped.map { model.work.agent($0.id) } ?? model.selectedAgent }
    /// This chat's page of the transcript: its scene's own, or the main scene's.
    private var page: AgentsModel { model.page(popped) }

    /// Open on a live tile (#4141): a scene of its own on an iPad, a cover on an iPhone.
    private var openTakeOver: OpenTakeOver {
        OpenTakeOver(supportsMultipleWindows: supportsMultipleWindows, openWindow: openWindow, model: model)
    }

    var body: some View {
        Group {
            if let agent {
                // The conversation with its panes beside it or over it (034).
                PaneHost(agent: agent) { conversation }
            } else if popped?.looked ?? (model.lookedForSelection == model.selection) {
                // A session that went while it was open: not an empty chat to type into,
                // which is New Session's (#2652), as on the Mac (#2651).
                SessionDeletedPage(next: sizeClass == .compact ? .goBack : .pickAnother)
            } else if let failure = page.transcriptLoadFailure {
                // Not looked for: its host did not answer, so it is not called deleted (#2743).
                SessionNotLoadedPage(failure: failure) { [model, popped] in
                    if let popped { await model.loadTranscript(of: popped) } else { await model.loadTranscript() }
                }
            } else {
                // Not looked for yet: on its way, not gone. Said only after 300 ms (#4795).
                DelayedProgress()
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
        // What the ⌘K command menu asked of the open chat (#4792); not of a popped-out one.
        .onChange(of: model.chatAsk, initial: true) {
            guard popped == nil, let ask = model.chatAsk else { return }
            model.chatAsk = nil
            switch ask {
            case .findInChat: if findsInChat { finding = true }
            case .openFile: if agent != nil { searchingFiles = true }
            case .prompts: if agent != nil { showingPrompts = true }
            }
        }
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
        // The pull, for VoiceOver and Switch Control, which cannot easily pull from an edge
        // now that the ··· menu has no panes (#2808).
        .accessibilityAction(named: "Show Panes") {
            if let agent { model.panes.state(for: agent.id).show(.exchanged) }
        }
        .environment(\.chatActions, actions)
        .environment(\.orgSandboxSetBy, model.sandboxSettings.setBy)
        // A file a message links to is on the Mac: it opens in Files, as a file a tool
        // call touched does (#548), a bare absolute path too, as on the Mac (#2754).
        // Links to the web are the system's.
        .environment(\.openURL, OpenURLAction { [actions] url in
            guard let fileURL = ChatLinkURL.fileURL(from: url) else { return .systemAction }
            actions.open(ToolCallLocation(path: fileURL.path(percentEncoded: false)))
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
                // What is wrong with the session's place, one strip at a time (#5034).
                if let agent { strips(for: agent) }
                // Under the banner, not over it: when the Mac has gone quiet, what
                // the agent last said it would do is the less urgent of the two.
                if let agent {
                    // What it works towards: the goal (#2742) and the plan, one Now card (#5033).
                    NowTopCard(agent: agent)
                }
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
                        Label("Panes", icon: "sidebar.right")
                    }
                    .accessibilityHint("Shows the page, files and terminal for this agent")
                }
            }
            if let agent {
                ToolbarItem(placement: .topBarTrailing) {
                    ChatMenu(state: menuState(agent),
                             find: { finding = true },
                             prompts: { showingPrompts = true },
                             openFile: { searchingFiles = true },
                             folderTerminal: openFolderTerminal)
                        .equatable()
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
        // A use of a secret with Ask before use waits the same way, as on the Mac (#4918).
        for request in model.work.secretUses(askedBy: agent.id) {
            if let use = request.secretUse {
                cards.append(WaitingCard(id: "secretUse:" + request.id.uuidString) {
                    SecretUseCard(request: request, use: use,
                                  answer: { await model.answerSecretUse(request, $0) },
                                  isDisabled: model.isStale(agent))
                        .chatColumn()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                })
            }
        }
        // The sandbox failure it waits on, once in the transcript, is an Ask here, as on the
        // Mac (#5031).
        if let record = waitingSandbox, let keepStopped = sandboxAnswer(carryOn: false) {
            cards.append(WaitingCard(id: "sandbox:" + agent.id.uuidString) {
                SandboxAsk(record: record, setBy: model.sandboxSettings.setBy,
                           keepStopped: keepStopped, continueWithout: sandboxAnswer(carryOn: true))
                    .chatColumn()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        // A policy stop that can still be raised, once in the transcript, is an Ask here (#5031).
        if let askForMore = actions.askForMore,
           let stop = PolicyStopAsks.shared.raisable(model.work.entries, agent: agent) {
            cards.append(WaitingCard(id: "policy:" + stop.id.uuidString) {
                PolicyStopAsk(refusal: stop.refusal, entryID: stop.id, askForMore: askForMore,
                              openPolicy: actions.openPolicy)
                    .chatColumn()
            })
        }
        // A view's Show or Send, once in its row, is an Ask here (#5031).
        for host in views.asking {
            cards.append(WaitingCard(id: "view:" + host.call.id.uuidString) {
                AppViewAsk(host: host)
                    .chatColumn()
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
        // It drives the screen, the browser or a simulator (#3004, #4140), as on the Mac: the
        // live tile. Open takes the browser or the simulator over in a scene of its own on an
        // iPad, a full-screen cover on an iPhone (#4141).
        let liveFrames = page.liveFrames.filter { $0.value.frame.agentID == agent.id }
        if agent.state == .running, !liveFrames.isEmpty {
            cards.append(WaitingCard(id: "live:" + agent.id.uuidString, asks: false) {
                LiveTile(frames: liveFrames, open: { [openTakeOver] source in
                    openTakeOver(TakeOverKey(agentID: agent.id, source: source))
                })
                .transition(.opacity)
            })
        }
        // Its drive_screen paused by the person's touch (#3004, US3), as on the Mac.
        if let pause = agent.desktopControlPause {
            cards.append(WaitingCard(id: "screen:" + agent.id.uuidString) {
                DesktopControlPauseCard(pause: pause,
                                        resume: { await model.resumeDesktopControl(agent.id) },
                                        takeOver: { await model.takeOverDesktopControl(agent.id) },
                                        isDisabled: model.isStale(agent))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        // A wait on sessions or on a time, the same card in the same place (#2750): it was
        // lines under the chat's head, with Carry on in the toolbar.
        if let (report, block) = model.work.openBlock(agent) {
            cards.append(WaitingCard(id: "block:" + agent.id.uuidString, asks: false) {
                BlockWaitCard(block: block, since: report.at, lines: model.blockLines(agent),
                              stop: { await model.carryOn(agent.id) },
                              help: AgentsModel.carryOnHelp(for: agent),
                              isDisabled: model.isStale(agent))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            })
        }
        // The agent's wait on events, under the questions, as on the Mac (#1995).
        if agent.eventWait?.isOpen == true, let status = model.work.waitStatus(of: agent) {
            // A wait only the person can settle is an Ask (#5031), in the chat column; any other
            // is a part of the Now card (#5033), which keeps the column itself.
            let asks = agent.eventWait?.lineResource == nil && agent.eventWait?.personLine != nil
            cards.append(WaitingCard(id: "wait:" + agent.id.uuidString, asks: asks) {
                WaitCard(status: status, eventWait: agent.eventWait,
                         lines: model.work.waitEventLines(of: agent),
                         continueNow: { await model.continueWaiting(of: agent.id, line: agent.eventWait?.lineResource) },
                         stop: { await model.cancelWait(of: agent.id) },
                         isDisabled: model.isStale(agent))
                    .chatColumn(asks)
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
                    // The conversation scrolls under the bar, as on the Mac (#3196): the
                    // page's own paper across the block, so its words do not read through
                    // the pills and the bar is the same colour as the page. On down to the
                    // screen's foot, under the home indicator.
                    .frame(maxWidth: .infinity)
                    .background(Paper.ground, ignoresSafeAreaEdges: .bottom)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
        // The scene's toast floats above it (#4737).
        .liftsRemoteToasts()
        .animation(ResponseMotion.snappy, value: isQuestionUp)
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

    /// Start now on a queued session (#5156), where its host has it; nil draws no button.
    private var startNow: (@MainActor (UUID) async -> Void)? {
        guard model.agent(agent?.id, has: Capability.agentsStartNow1) else { return nil }
        return { [model] agentID in await model.startNow(agentID) }
    }

    private var actions: ChatActions {
        let agentID = agent?.id
        // This Mac's page at its Resources (#116, #4027), as the Mac opens its machine page
        // there (#3629). Not in a scene of its own, which has no sidebar: there the line is
        // words alone (#2447).
        var openLease: (@MainActor (ResourceName) -> Void)?
        if popped == nil {
            openLease = { [model] _ in
                model.resourcesAsked = true
                model.sidebarItem = .machine(.mac)
            }
        }
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
            startNow: startNow,
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
            stopBackground: { [model] item, agentID in await model.stopBackground(item, of: agentID) },
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
            sending: { [model] agentID in model.work.sending(to: agentID) },
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
            capacityStart: { [model] agent in model.work.capacityStartLine(agent) },
            openLease: openLease,
            fromLine: { [model] sender in model.work.fromLine(sender) },
            // Ask for More on a Stopped by a policy card (#3262); the Remote has no Spending.
            askForMore: { [model] in try await PolicyLayersWords.askForMore(on: model.controlPlane) },
            undoTurn: undoTurn)
    }

    /// Undo These Changes on a turn's card (#3437): not on an archived session, nor on a
    /// host too old to undo.
    private var undoTurn: (@MainActor (UUID, Bool) async throws -> DaemonAPI.UndoTurnResult)? {
        guard let agent, agent.state != .archived, model.host(agent.host, has: Capability.changesUndo1) else { return nil }
        return { [model] turn, confirmed in try await model.undoTurn(turn, of: agent.id, confirmed: confirmed) }
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

    /// What the ··· menu shows, read here once per update so the menu itself reads no live
    /// state (#2808).
    private func menuState(_ agent: Agent) -> ChatMenuState {
        ChatMenuState(agentID: agent.id,
                      isArchived: agent.state == .archived,
                      isBlocked: model.isBlocked(agent),
                      carryOnHelp: AgentsModel.carryOnHelp(for: agent),
                      isStale: model.isStale(agent),
                      isActing: model.acting(agent.id) != nil,
                      isPinned: model.isPinned(agent),
                      canMute: model.canMute(agent),
                      isMuted: agent.isMuted,
                      findsOnHost: findsInChat,
                      isPopped: popped != nil,
                      leavesChat: popped == nil || sceneFolder != nil,
                      hasFolderTerminal: openFolderTerminal != nil)
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

/// What the ··· menu shows, read from the model once per update (#2808). It changes only
/// when something is done to the session, not on each streamed line, so the open menu is
/// not drawn again under the finger, which scrolls it back to its top.
struct ChatMenuState: Equatable {
    let agentID: UUID
    let isArchived: Bool
    let isBlocked: Bool
    let carryOnHelp: String
    let isStale: Bool
    /// Something asked of the whole session is on its way (#87): Archive waits for it.
    let isActing: Bool
    let isPinned: Bool
    let canMute: Bool
    let isMuted: Bool
    /// Whether the chat's host can find: on one too old (#1748) the item is greyed, with
    /// the update help, not left out (#1867).
    let findsOnHost: Bool
    /// In a scene of its own (#888): no Find, Prompts or Open in New Window.
    let isPopped: Bool
    /// Archive leaves the chat, back to the folder's list (#2090).
    let leavesChat: Bool
    let hasFolderTerminal: Bool
}

/// The rarer things to do with this agent, and on a phone, where the bar has no room
/// for them, Pin and Archive (#586) and Carry on (#981). Not the panes, which the pull
/// from the right edge brings in (#1560, #2808).
///
/// Its body reads nothing that streams: only `state`, which the chat compares before
/// drawing it again (#2808).
private struct ChatMenu: View, Equatable {
    @Environment(RemoteModel.self) private var model
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.openWindow) private var openWindow
    let state: ChatMenuState
    /// Find in Chat (#1532), over the chat.
    let find: () -> Void
    /// The Prompts list (#1658), over the chat.
    let prompts: () -> Void
    /// Open File… (#415), over the chat.
    let openFile: () -> Void
    /// The folder's own shell (#418), on a chat in the main scene.
    let folderTerminal: OpenFolderTerminal?
    /// Whether the chat draws the agent's thoughts (#1725): View ▸ Show Thoughts on the Mac,
    /// this menu here, which has no View menu (#2383).
    @AppStorage(ChatThoughts.showsKey, store: WindowDefaults.store) private var showsThoughts = ChatThoughts.showsAtFirst

    nonisolated static func == (lhs: ChatMenu, rhs: ChatMenu) -> Bool { lhs.state == rhs.state }

    var body: some View {
        let id = state.agentID
        Menu {
            // Blocked (039): first, on a phone. The card in the chat keeps its own (#981).
            if sizeClass != .regular, state.isBlocked {
                Button(AgentsModel.carryOnLabel, icon: "play.circle") {
                    Task { await model.carryOn(id) }
                }
                .disabled(state.isStale)
                .accessibilityHint(state.carryOnHelp)
                Divider()
            }
            if !state.isPopped {
                // A menu draws a label's second line under the item: the update help.
                Button(action: find) {
                    Label {
                        Text("Find in Chat")
                        if !state.findsOnHost { Text(UpdateWords.hostNeedsUpdate) }
                    } icon: {
                        Image(icon: "text.magnifyingglass")
                    }
                }
                .disabled(!state.findsOnHost)
                Button("Prompts", icon: "list.number", action: prompts)
            }
            Button("Open File…", icon: "magnifyingglass", action: openFile)
            Button(ChatThoughts.menuTitle(showsThoughts: showsThoughts), icon: "brain") { showsThoughts.toggle() }
                .accessibilityHint(ChatThoughts.menuHelp)
            // One menu in the bar, not two (#2808); Control-` still opens it from a keyboard.
            if let folderTerminal, state.hasFolderTerminal {
                Button("Folder Terminal", icon: "apple.terminal") { folderTerminal() }
            }
            // The main scene's chat, in a scene of its own (#888), where the device has more
            // than one.
            if !state.isPopped, supportsMultipleWindows {
                Button("Open in New Window", icon: "macwindow.badge.plus") {
                    openWindow(id: PoppedChat.sceneID, value: id)
                }
            }
            if !state.isArchived {
                // As the Mac's Session menu has them (#342, #751).
                Button("Rename…", icon: "pencil") {
                    if let agent = model.work.agent(id) { model.askToRename(agent) }
                }
                .disabled(state.isStale)
                if state.canMute {
                    Button {
                        Task { await model.setMuted(id, !state.isMuted) }
                    } label: {
                        Label(MuteWords.label(muted: state.isMuted), icon: MuteWords.symbol(muted: state.isMuted))
                        // What it does, under it (#2086): iOS menus draw a second Text as a subtitle.
                        Text(MuteWords.help(muted: state.isMuted))
                    }
                    .disabled(state.isStale)
                }
                Button {
                    Task { await model.fork(id) }
                } label: {
                    Label("Branch", icon: "arrow.triangle.branch")
                }
                .disabled(state.isStale)
                // To another of the person's machines, with its unpushed work (#4037).
                if let agent = model.work.agent(id) { MoveToMachineButton(agent: agent) }
                if sizeClass != .regular {
                    Divider()
                    Button {
                        guard let agent = model.work.agent(id) else { return }
                        Task { await model.setPinned(agent, !state.isPinned) }
                    } label: {
                        Label(state.isPinned ? "Unpin" : "Pin", icon: state.isPinned ? "pin.slash" : "pin")
                    }
                    .disabled(state.isStale)
                    Button {
                        Task { await model.archive(id, andLeave: state.leavesChat) }
                    } label: {
                        Label("Archive", icon: "archivebox")
                    }
                    .disabled(state.isStale || state.isActing)
                }
            } else {
                Divider()
                Button("Unarchive", icon: "tray.and.arrow.up") {
                    Task { await model.unarchive(id) }
                }
                .disabled(state.isStale)
            }
        } label: {
            Label("Actions", icon: "ellipsis.circle")
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
extension RemoteChatView {
    /// The session's strips (#5034): its host, folder, account, allowance and limit, in that
    /// order, one at a time with "+N more". The limit's left the prompt bar for here.
    @ViewBuilder
    func strips(for agent: Agent) -> some View {
        let reason = RemoteMissingFolderStrip.isShown(agent) ? nil : model.accountMoveReason(agent)
        let kinds = SessionStripKind.allCases.filter { kind in
            switch kind {
            case .host: HostOfflineStrip.isShown(agent.host, model: model)
            case .folder: RemoteMissingFolderStrip.isShown(agent)
            case .account: reason != nil
            case .allowance: RemoteContinueWhenBackStrip.isShown(agent, model: model)
            case .limit: agent.state != .archived
                && CostLimitStrip.isShown(agent: agent, limits: model.costLimits, costState: model.costState)
            }
        }
        StripStack(kinds: kinds) { kind in
            switch kind {
            case .host: HostOfflineStrip(host: agent.host)
            case .folder: RemoteMissingFolderStrip(agent: agent)
            case .account: RemoteAccountMoveStrip(agent: agent, reason: reason ?? "")
            case .allowance: RemoteContinueWhenBackStrip(agent: agent)
            case .limit:
                CostLimitStrip(agent: agent, limits: model.costLimits, costState: model.costState,
                               goOn: { Task { await model.letThisAgentGoOn(agent) } })
            }
        }
        .paneBannerInset()
        .remoteBannerGround()
    }
}

private struct OfferedFileStrip: View {
    @Environment(RemoteModel.self) private var model
    let file: ShownFile

    var body: some View {
        HStack(spacing: 10) {
            Image(icon: ShownFile.isMarkdown(file.url) ? "doc.richtext" : "doc.text")
                .foregroundStyle(Paper.secondary)
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
                Label("Not now", icon: "xmark")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .paperWell(in: Rectangle())
    }
}
