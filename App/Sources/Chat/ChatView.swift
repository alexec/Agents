import AgentsKitCore
import SwiftUI

/// The right-hand side for a selected session. A new session starts on the folder page
/// (`FolderAgentsView`), not here (#2651).
///
/// The bar floats: the transcript runs the full height of
/// the pane and scrolls underneath it, the way controls sit over content everywhere
/// else on the system. The transcript is told how tall the bar is so the last thing an
/// agent said can still be scrolled clear of it. What waits on the person is the last
/// thing in the transcript, not over it (#723).
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    @Environment(SidebarStates.self) private var states
    @Environment(\.openURL) private var openURL
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    /// Set in a window of its own (#826): this session, not the selection.
    @Environment(\.poppedChat) private var popped
    /// Whether this window has an inspector: not a session's own window (#826), but a
    /// folder's does (#1089).
    @Environment(\.windowHasInspector) private var hasInspector
    @Environment(WindowRequests.self) private var requests
    /// Find in Chat is up over the chat (#1532).
    @State private var finding = false
    /// The Prompts list is up over the chat (#1658).
    @State private var showingPrompts = false
    @State private var formHeight: CGFloat = 0
    /// The open chat's views (#187), torn down when another chat opens.
    @State private var views = AppViewStore()

    private var agent: Agent? { popped.map { model.work.agent($0.id) } ?? model.selectedAgent }

    var body: some View {
        Group {
            if let agent {
                ZStack(alignment: .bottom) {
                    Transcript(agent: agent, bottomInset: formHeight, cards: cards)
                        // What was exchanged, a swipe away, as on the phone.
                        .swipeToShowPane(show: {
                            // A session's own window has no inspector (#826).
                            guard hasInspector else { return }
                            frame.pane = .artifacts
                            if !frame.isOpen, SidebarFrame.fits(inWindowOf: frame.windowWidth) { frame.open() }
                        }, hide: { frame.isOpen = false })
                        // Over the chat rather than in the toolbar, whose trailing end
                        // is above the sidebar whenever the sidebar is open. The
                        // transcript scrolls on under it, as it does under the prompt.
                        .safeAreaInset(edge: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                // What is wrong with the session's place, one strip at a time (#5034).
                                strips(for: agent)
                                actions(for: agent)
                                if finding, popped == nil {
                                    ChatFindBar(agentID: agent.id,
                                                search: { [model] text in await model.find(text, in: agent.id) },
                                                go: { [model] match in await model.reveal(match) },
                                                close: { finding = false })
                                }
                                // What it works towards: the goal (#2742) and the plan
                                // (#341), one Now card with two rows (#5033).
                                NowTopCard(agent: agent)
                            }
                            // On the page's own paper, across the whole pane: the
                            // transcript scrolls under this strip, and without a ground
                            // of its own its words showed through between the buttons.
                            // Kept to the strip's own bounds: a colour's background fills
                            // the safe area too by default, which here is the transcript.
                            .frame(maxWidth: .infinity)
                            .background(Paper.ground, ignoresSafeAreaEdges: [])
                        }
                        // Stopped at the pane's top. A scroll view draws on up under the
                        // window's toolbar, which paints no ground of its own since #456,
                        // so the chat showed through behind the title and folder name.
                        .clipped()
                    form
                }
            } else if model.lookedForSelection == model.selection {
                // A selection that names no session its host knows: it went while it was
                // selected. Not a start form, which is the folder page's (#2651), as a
                // session's own window says it (#826).
                SessionDeletedPage(next: .pickAnother)
            } else if let failure = model.work.transcriptLoadFailure {
                // Not looked for: its host did not answer, so it is not called deleted (#2748).
                SessionNotLoadedPage(failure: failure) { await model.loadTranscript() }
            } else {
                // Not looked for yet, as the selection kept from the last launch: on its
                // way, not gone. Said only after 300 ms, as a network wait (#4795).
                DelayedProgress(controlSize: .small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Title stays on ContentView's detail: one owner for the window title.
        .environment(\.chatActions, chatActions)
        .environment(\.orgSandboxSetBy, model.sandboxSettings.setBy)
        .environment(\.appViewStore, views)
        .environment(\.appViewActions, agent.map(appViewActions))
        // A view full screen is drawn in the chat's place, as a pinned page is (#187).
        .overlay {
            if let id = views.fullscreen, let host = views.existing(id) {
                AppViewFullscreen(host: host)
            }
        }
        .onChange(of: agent?.id) { views.tearDownAll() }
        .onChange(of: requests.wantsChatFind) {
            guard requests.wantsChatFind, popped == nil else { return }
            requests.wantsChatFind = false
            finding = true
        }
        .onChange(of: requests.wantsPrompts) {
            guard requests.wantsPrompts, popped == nil else { return }
            requests.wantsPrompts = false
            showingPrompts = agent != nil
        }
        .sheet(isPresented: $showingPrompts) {
            if let agent {
                PromptsList(agent: agent, page: model.work,
                            go: { [model] prompt in model.focusEntry(prompt.id) },
                            branch: branchFrom(agent).map { branch in { branch($0.id, $0.text) } },
                            loadEarlier: { [model] in await model.loadEarlier() },
                            close: { showingPrompts = false },
                            branchNeedsUpdate: branchNeedsUpdate(agent))
            }
        }
        // A view read when the link dropped may never be answered: read it again (#978).
        .onChange(of: model.isConnected) { if model.isConnected { views.reconnected() } }
    }

    /// Branch from Here (#1658), on a prompt in the chat or in the Prompts list: as Branch,
    /// not on an archived session.
    private func branchFrom(_ agent: Agent?) -> (@MainActor (UUID, String) -> Void)? {
        // Not on a host too old to branch (#1748).
        guard let agent, agent.state != .archived, model.host(agent.host, has: Capability.chatBranch1) else { return nil }
        return { [model] entryID, text in Task { await model.branch(from: entryID, of: agent.id, text: text) } }
    }

    /// Branch from Here kept, greyed, on a host too old to branch (#1866).
    private func branchNeedsUpdate(_ agent: Agent?) -> Bool {
        guard let agent, agent.state != .archived else { return false }
        return !model.host(agent.host, has: Capability.chatBranch1)
    }

    /// What a view in the chat may ask of the Mac (#187): the host the chat is on, the
    /// person's own send, the default browser, a new agent's form (#834), and a send to the
    /// session on a branch (#837).
    private func appViewActions(_ agent: Agent) -> AppViewActions {
        AppViewActions(
            agentID: agent.id,
            call: { [model] method, params in try await model.viewCall(agent.id, method, params) },
            send: { [model] text in await model.send(text, to: agent.id) },
            openLink: { [openURL] url in openURL(url) },
            pin: { [model] view in
                await model.pinView(view, in: FolderKey(host: agent.host, folder: agent.folderPath))
            },
            startAgent: { [model] start in
                model.offerStart(start, in: FolderKey(host: agent.host, folder: agent.folderPath))
            },
            // The session on a pull request's branch (#837), asked under the view first.
            recipient: { [model] message in
                model.recipient(of: message, in: FolderKey(host: agent.host, folder: agent.folderPath))
            },
            sendTo: { [model] id, text in await model.send(text, to: id) })
    }

    /// Run a command from a reply in the session's Terminal pane (#1533); a window of its
    /// own has none.
    private var runCommand: (@MainActor (String) -> Void)? {
        guard hasInspector, let agent else { return nil }
        return { [model, frame, states] command in
            let state = states.state(for: agent.id)
            state.frontShellZero()
            frame.pane = .terminal
            if !frame.isOpen { frame.open() }
            Task {
                await model.runCommand(command, in: agent.id)
                // The pane, shown just now, asks the host for its shells, and the answer
                // may have come before shell 0 was open again.
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

    /// What the shared chat rows mean on a Mac (033).
    private var chatActions: ChatActions {
        ChatActions(
            // The editor the Mac opens that file with, which is the one the user chose.
            open: { [model, agent] location in model.open(URL(filePath: location.path), on: agent?.host ?? .mac) },
            terminalOutput: { [model, popped] id in (popped?.work.terminalOutput ?? model.terminalOutput)[id] ?? "" },
            unqueue: { [model] prompt, agentID in await model.unqueue(prompt, from: agentID) },
            editQueued: { [model] prompt, text, agentID in await model.editQueued(prompt, text: text, of: agentID) },
            canEditQueued: { [model] agentID in model.agent(agentID, has: Capability.agentsEditQueued1) },
            quote: { [model, agent] words in model.offeredQuote = PromptOffer(agentID: agent?.id, words: words) },
            branchFrom: branchFrom(agent),
            branchNeedsUpdate: branchNeedsUpdate(agent),
            runCommand: runCommand,
            tellAgent: tellAgent,
            sendNow: { [model] prompt, agentID in await model.sendNow(prompt, to: agentID) },
            canSendNow: { [model] runtimeID in runtimeID.flatMap { model.accounts[$0]?.canSteer } ?? false },
            startNow: startNow,
            acting: { [model] agentID in model.acting(agentID) },
            recipient: { [model] agentID in model.answerRecipient(agentID) },
            // The sidebar's Changes pane, open at that edit (035 FR-014).
            showEdit: { [model, frame, states, agent, hasInspector] diff, toolCallID in
                guard let agent else { return }
                // A window of its own has no Changes pane: the file opens in the editor (#826).
                if !hasInspector { return model.open(URL(filePath: diff.path), on: agent.host) }
                states.state(for: agent.id).changesSelection = ChangesSelection(
                    path: ReportedChanges.key(diff.path), toolCallID: toolCallID)
                frame.pane = .changes
                if !frame.isOpen { frame.open() }
            },
            // A turn's Changed files card (#5035): the Changes pane, at the file or its list.
            showChanges: { [model, frame, states, agent, hasInspector] path in
                guard let agent else { return }
                // A window of its own has no Changes pane: one file opens in the editor (#826).
                if !hasInspector {
                    if let path { model.open(URL(filePath: path), on: agent.host) }
                    return
                }
                states.state(for: agent.id).changesSelection = path.map { ChangesSelection(path: ReportedChanges.key($0)) }
                frame.pane = .changes
                if !frame.isOpen { frame.open() }
            },
            // The sidebar's Background pane, at that subagent (057, frame C).
            subagentSteps: { [model, frame, states, agent, hasInspector, openWindow] id in
                guard let agent else { return }
                // The Background pane is the main window's: the session opens there (#826).
                if !hasInspector { return model.showInMainWindow(agent.id, opening: openWindow) }
                states.state(for: agent.id).subagent = id
                frame.pane = .background
                if !frame.isOpen { frame.open() }
            },
            backgroundOutput: { [model, agent] item in
                guard let agent else { return }
                Task { await BackgroundOutput.open(item, of: agent, model: model) }
            },
            stopBackground: { [model] item, agentID in await model.stopBackground(item, of: agentID) },
            turnEntries: { [model] agentID, range in await model.turnEntries(agentID, range) },
            reloadTranscript: { [model, popped] in
                if let popped { await model.loadTranscript(of: popped) } else { await model.loadTranscript() }
            },
            continueWithoutSandbox: sandboxAnswer(carryOn: true),
            keepStopped: sandboxAnswer(carryOn: false),
            waitingSandbox: agent?.pendingSandboxFailure,
            kept: { [model] agentID in model.kept(for: agentID) },
            dropKept: { [model] in await model.dropKept($0) },
            retryKept: { [model] in await model.retryKept($0) },
            sending: { [model] agentID in model.work.sending(to: agentID) },
            hostName: { [model] in model.hosts.label($0) },
            // A card in the chat opens its file in Files, as the agent's call did (#836).
            showFile: { [model, frame, states, agent, hasInspector] file in
                guard let agent else { return }
                model.work.rememberChart(file)
                // No Files pane in a window of its own: the file opens in the editor (#826).
                if !hasInspector { return model.open(file.url, on: agent.host) }
                let state = states.state(for: agent.id)
                state.folder = file.url.deletingLastPathComponent()
                state.openFile = file.url
                state.openLine = file.line
                if HTMLPageScope.isHTML(file.url) { state.htmlShowsSource = false }
                frame.pane = .files
                if !frame.isOpen { frame.open() }
            },
            readFile: { [model, agent] path in
                guard let agent else { return nil }
                return try? await model.serverFiles(agent.host).read(agentID: agent.id, path: path)
            },
            picture: { [model, agent] file in
                guard let agent,
                      case .image(let bytes, _, _)? = try? await model.serverFiles(agent.host)
                        .read(agentID: agent.id, path: file.path),
                      let image = NSImage(data: bytes) else { return nil }
                return Image(nsImage: image)
            },
            leaseStatus: { [model] agentID in model.work.leaseStatus(of: agentID) },
            capacityStart: { [model] agent in model.work.capacityStartLine(agent) },
            // Resources at the resource, as the line names it (036 FR-011).
            openLease: { [model] name in model.showResources(at: name) },
            fromLine: { [model] sender in model.work.fromLine(sender) },
            openPolicy: { [model, requests, openSettings] action in
                Self.openPolicy(action, model: model, requests: requests, openSettings: openSettings)
            },
            askForMore: { [model] in try await PolicyLayersWords.askForMore(on: model.controlRequests) },
            undoTurn: undoTurn)
    }

    /// Undo These Changes on a turn's card (#3437): not on an archived session, nor on a
    /// host too old to undo.
    private var undoTurn: (@MainActor (UUID, Bool) async throws -> DaemonAPI.UndoTurnResult)? {
        guard let agent, agent.state != .archived, model.host(agent.host, has: Capability.changesUndo1) else { return nil }
        return { [model] turn, confirmed in try await model.undoTurn(turn, of: agent.id, confirmed: confirmed) }
    }

    /// A Stopped by a policy card's button (#2957, FR-025): the pane of the layer that
    /// decides. A folder's opens its Project Settings at Policy, on that folder.
    private static func openPolicy(_ action: PolicyLayersWords.StopAction, model: AppModel,
                                   requests: WindowRequests, openSettings: OpenSettingsAction) {
        switch action {
        case .changeYours:
            model.settingsPaneAsked = .agentsPolicy
            openSettings()
        case .changeFolder(let path):
            let folder = URL(filePath: path)
            if model.selectedFolder?.standardizedFileURL != folder.standardizedFileURL { model.selectedFolder = folder }
            requests.projectSettings = .policy
        case .openSpending:
            model.settingsPaneAsked = .spending
            openSettings()
        case .seeOrganisation:
            model.settingsPaneAsked = .policy
            openSettings()
        }
    }

    /// The sandbox card's answer for the open agent (064).
    private func sandboxAnswer(carryOn: Bool) -> (@MainActor () async -> Void)? {
        guard let id = agent?.id, agent?.pendingSandboxFailure != nil else { return nil }
        let model = model
        return { await model.answerSandbox(id, carryOn: carryOn) }
    }

    /// The session's strips (#5034): its host, folder, account, allowance and limit, in that
    /// order, one at a time with "+N more".
    @ViewBuilder
    private func strips(for agent: Agent) -> some View {
        let reason = model.accountMoveReason(agent)
        let kinds = SessionStripKind.allCases.filter { kind in
            switch kind {
            case .host: OfflineStrip.isShown(agent.host, model: model)
            case .folder: MissingFolderStrip.isShown(agent, model: model)
            case .account: reason != nil && !MissingFolderStrip.isShown(agent, model: model)
            case .allowance: ContinueWhenBackStrip.isShown(agent, model: model)
            case .limit: agent.state != .archived
                && CostLimitStrip.isShown(agent: agent, limits: model.costLimits, costState: model.costState)
            }
        }
        StripStack(kinds: kinds) { kind in
            switch kind {
            case .host: OfflineStrip(host: agent.host)
            case .folder: MissingFolderStrip(agent: agent)
            case .account: AccountMoveStrip(agent: agent, reason: reason ?? "")
            case .allowance: ContinueWhenBackStrip(agent: agent)
            case .limit:
                CostLimitStrip(agent: agent, limits: model.costLimits, costState: model.costState,
                               goOn: { Task { await model.letThisAgentGoOn(agent) } },
                               raise: {
                                   // The limits are rules of Agents ▸ Policy (#2957): open Settings there.
                                   model.settingsPaneAsked = .agentsPolicy
                                   openSettings()
                               })
            }
        }
        .chatColumn()
        .padding(.top, kinds.isEmpty ? 0 : 8)
    }

    /// What can be done to the chat as a whole, at the right-hand edge of its column.
    @ViewBuilder
    private func actions(for agent: Agent) -> some View {
        if agent.state == .archived {
            // Matching the phone: an archived chat's own page is where Unarchive lives,
            // not only on the row you left it from.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    Task { await model.unarchive(agent.id) }
                } label: {
                    Label("Unarchive", icon: "tray.and.arrow.up")
                }
                .buttonStyle(.paper)
                .appText(.fine)
                .help("Unarchive this session (⌥⌘⌫)")
            }
            .chatColumn()
            .padding(.vertical, 8)
        }
    }

    private var selectedHostOffline: Bool {
        model.hosts.isOffline(agent?.host ?? .mac)
    }

    private var offlineHelp: String {
        model.offlineHelp(for: agent?.host ?? .mac)
    }

    /// What waits on the person, then the agent's wait on events, at the end of the
    /// transcript (#723, #1995). None when nothing waits.
    private var cards: [WaitingCard] {
        guard let agent else { return [] }
        var cards: [WaitingCard] = []
        for request in model.work.permissions(for: agent.id) {
            cards.append(WaitingCard(id: request.id.uuidString) {
                PermissionView(request: request)
                    .disabled(selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // A change its agent made to the folder's own files waits the same way (#531).
        for change in model.work.guardedChanges(askedIn: agent.id) {
            cards.append(WaitingCard(id: "guarded:" + change.id) {
                GuardedChangeQuestion(change: change, key: FolderKey(host: agent.host, folder: agent.folderPath))
                    .chatColumn()
            })
        }
        // A form waits the same way a permission question does.
        if let request = model.work.elicitation(for: agent.id) {
            cards.append(WaitingCard(id: request.id.uuidString) {
                // A fresh card per form, so the answers and the step reached on one
                // are not carried into the next.
                ElicitationView(request: request)
                    .id(request.id)
                    .disabled(selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // A use of a secret with Ask before use waits the same way (#4918): its Needs you row
        // stays, and an answer on either takes both away.
        for request in model.work.secretUses(askedBy: agent.id) {
            if let use = request.secretUse {
                cards.append(WaitingCard(id: "secretUse:" + request.id.uuidString) {
                    SecretUseCard(request: request, use: use,
                                  answer: { await model.answerSecretUse(request, $0) },
                                  isDisabled: selectedHostOffline)
                        .chatColumn()
                        .help(selectedHostOffline ? offlineHelp : "")
                })
            }
        }
        // The sandbox failure it waits on, once in the transcript, is an Ask here (#5031).
        if let record = agent.pendingSandboxFailure, let keepStopped = sandboxAnswer(carryOn: false) {
            cards.append(WaitingCard(id: "sandbox:" + agent.id.uuidString) {
                SandboxAsk(record: record, setBy: model.sandboxSettings.setBy,
                           keepStopped: keepStopped, continueWithout: sandboxAnswer(carryOn: true))
                    .chatColumn()
                    .disabled(selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // A policy stop that can still be raised, once in the transcript, is an Ask here (#5031).
        if let askForMore = chatActions.askForMore,
           let stop = PolicyStopAsks.shared.raisable((popped?.work ?? model.work).entries, agent: agent) {
            cards.append(WaitingCard(id: "policy:" + stop.id.uuidString) {
                PolicyStopAsk(refusal: stop.refusal, entryID: stop.id, askForMore: askForMore,
                              openPolicy: chatActions.openPolicy)
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
        // An ask to be archived waits the same way, last when asked at once (#827).
        if agent.asksToArchive {
            cards.append(WaitingCard(id: "archive:" + agent.id.uuidString) {
                ArchiveRequestCard(agent: agent,
                                   approve: { await model.archive(agent.id, andLeave: true) },
                                   keep: { await model.keepSession(agent) },
                                   isDisabled: selectedHostOffline || model.acting(agent.id) != nil)
                    .chatColumn()
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // It drives the screen, the browser or a simulator (#3004, #4140): the live tile, above
        // any pause card. Open takes the browser or the simulator over in a window of its own
        // (#4141), also from a chat in a window of its own.
        let liveFrames = model.work.liveFrames.filter { $0.value.frame.agentID == agent.id }
        if agent.state == .running, !liveFrames.isEmpty {
            cards.append(WaitingCard(id: "live:" + agent.id.uuidString, asks: false) {
                LiveTile(frames: liveFrames, open: { [openWindow] source in
                    openWindow(id: TakeOverKey.sceneID, value: TakeOverKey(agentID: agent.id, source: source))
                })
            })
        }
        // Its drive_screen paused by the person's touch (#3004, US3): Resume or Take Over.
        if let pause = agent.desktopControlPause {
            cards.append(WaitingCard(id: "screen:" + agent.id.uuidString) {
                DesktopControlPauseCard(pause: pause,
                                        resume: { await model.resumeDesktopControl(agent.id) },
                                        takeOver: { await model.takeOverDesktopControl(agent.id) },
                                        isDisabled: selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // A wait on sessions or on a time, the same card in the same place (#2750): it was
        // a strip under the chat's head with Carry on.
        if let (report, block) = model.work.openBlock(agent) {
            cards.append(WaitingCard(id: "block:" + agent.id.uuidString, asks: false) {
                BlockWaitCard(block: block, since: report.at, lines: model.blockLines(agent),
                              stop: { await model.carryOn(agent.id) },
                              help: AgentsModel.carryOnHelp(for: agent),
                              isDisabled: selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // The agent's wait on events, under the questions (#1995): it was a capsule over
        // the prompt.
        if agent.eventWait?.isOpen == true, let status = model.work.waitStatus(of: agent) {
            // A wait only the person can settle is an Ask (#5031), in the chat column; any other
            // is a part of the Now card (#5033), which keeps the column itself.
            let asks = agent.eventWait?.lineResource == nil && agent.eventWait?.personLine != nil
            cards.append(WaitingCard(id: "wait:" + agent.id.uuidString, asks: asks) {
                WaitCard(status: status, eventWait: agent.eventWait,
                         lines: model.work.waitEventLines(of: agent),
                         continueNow: { await model.continueWaiting(of: agent.id, line: agent.eventWait?.lineResource) },
                         stop: { await model.cancelWait(of: agent.id) },
                         isDisabled: selectedHostOffline)
                    .chatColumn(asks)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        return cards
    }

    private var form: some View {
        PromptBar()
            // The transcript scrolls under the bar (#3196): the page's own paper across
            // the whole block, so its words do not read through the pills or between
            // them, and the bar is the same colour as the page. Kept to its own bounds.
            .frame(maxWidth: .infinity)
            .background(Paper.ground, ignoresSafeAreaEdges: [])
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
            // The window's toasts float above the bar (#4737).
            .liftsToasts()
    }
}
