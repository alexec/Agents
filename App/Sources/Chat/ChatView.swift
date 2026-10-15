import AgentsKitCore
import SwiftUI

/// The right-hand side, whether or not there is an agent yet.
///
/// One view rather than two, because a new chat has to turn into the chat. The prompt
/// bar sits in the middle of an empty pane and moves to the foot of it when the
/// conversation starts, and it is the same bar throughout.
///
/// Once there is a conversation the bar floats: the transcript runs the full height of
/// the pane and scrolls underneath it, the way controls sit over content everywhere
/// else on the system. The transcript is told how tall the bar is so the last thing an
/// agent said can still be scrolled clear of it. What waits on the person is the last
/// thing in the transcript, not over it (#723).
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    @Environment(SidebarStates.self) private var states
    @Environment(\.openURL) private var openURL
    /// Set in a window of its own (#826): this session, not the selection.
    @Environment(\.poppedChat) private var popped
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
                            // A window of its own has no inspector (#826).
                            guard popped == nil else { return }
                            frame.pane = .artifacts
                            if !frame.isOpen, SidebarFrame.fits(inWindowOf: frame.windowWidth) { frame.open() }
                        }, hide: { frame.isOpen = false })
                        // Over the chat rather than in the toolbar, whose trailing end
                        // is above the sidebar whenever the sidebar is open. The
                        // transcript scrolls on under it, as it does under the prompt.
                        .safeAreaInset(edge: .top, spacing: 0) {
                            VStack(spacing: 0) {
                                OfflineStrip(host: agent.host)
                                actions(for: agent)
                                // What it said it would do, as the phone has it (#341).
                                CurrentPlanStrip(agent: agent)
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
                        // so the chat showed through behind the title and project name.
                        .clipped()
                    form
                }
            } else {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    CrowdMark()
                        .frame(width: 220)
                        .padding(.bottom, 28)
                    form
                    Spacer(minLength: 0)
                }
            }
        }
        // The prompt bar moving between the middle of an empty pane and the foot of a
        // chat. Not one chat changing for another: animating that faded the old rows out
        // for a quarter of a second while the new ones were built, and every frame of it
        // redrew the whole pane, which was most of the cost of opening a chat (#90).
        .animation(.snappy(duration: 0.28), value: (popped?.id ?? model.selection) == nil)
        // Title stays on ContentView's detail: one owner for the window title.
        .environment(\.chatActions, chatActions)
        .environment(\.appViewStore, views)
        .environment(\.appViewActions, agent.map(appViewActions))
        // A view full screen is drawn in the chat's place, as a pinned page is (#187).
        .overlay {
            if let id = views.fullscreen, let host = views.existing(id) {
                AppViewFullscreen(host: host)
            }
        }
        .onChange(of: agent?.id) { views.tearDownAll() }
        // A view read when the link dropped may never be answered: read it again (#978).
        .onChange(of: model.isConnected) { if model.isConnected { views.reconnected() } }
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
                await model.pinView(view, in: ProjectKey(host: agent.host, folder: agent.projectFolder))
            },
            startAgent: { [model] start in
                model.offerStart(start, in: ProjectKey(host: agent.host, folder: agent.projectFolder))
            },
            // The session on a pull request's branch (#837), asked under the view first.
            recipient: { [model] message in
                model.recipient(of: message, in: ProjectKey(host: agent.host, folder: agent.projectFolder))
            },
            sendTo: { [model] id, text in await model.send(text, to: id) })
    }

    /// What the shared chat rows mean on a Mac (033).
    private var chatActions: ChatActions {
        ChatActions(
            // The editor the Mac opens that file with, which is the one the user chose.
            open: { [model, agent] location in model.open(URL(filePath: location.path), on: agent?.host ?? .mac) },
            terminalOutput: { [model, popped] id in (popped?.work.terminalOutput ?? model.terminalOutput)[id] ?? "" },
            unqueue: { [model] prompt, agentID in await model.unqueue(prompt, from: agentID) },
            sendNow: { [model] prompt, agentID in await model.sendNow(prompt, to: agentID) },
            canSendNow: { [model] runtimeID in runtimeID.flatMap { model.accounts[$0]?.canSteer } ?? false },
            acting: { [model] agentID in model.acting(agentID) },
            recipient: { [model] agentID in model.answerRecipient(agentID) },
            // The sidebar's Changes pane, open at that edit (035 FR-014).
            showEdit: { [model, frame, states, agent, popped] diff, toolCallID in
                guard let agent else { return }
                // A window of its own has no Changes pane: the file opens in the editor (#826).
                if popped != nil { return model.open(URL(filePath: diff.path), on: agent.host) }
                states.state(for: agent.id).changesSelection = ChangesSelection(
                    path: ReportedChanges.key(diff.path), toolCallID: toolCallID)
                frame.pane = .changes
                if !frame.isOpen { frame.open() }
            },
            // The sidebar's Background pane, at that subagent (057, frame C).
            subagentSteps: { [model, frame, states, agent, popped] id in
                guard let agent else { return }
                // The Background pane is the main window's: the session opens there (#826).
                if popped != nil { return model.showInMainWindow(agent.id) }
                states.state(for: agent.id).subagent = id
                frame.pane = .background
                if !frame.isOpen { frame.open() }
            },
            backgroundOutput: { [model, agent] item in
                guard let agent else { return }
                Task { await BackgroundOutput.open(item, of: agent, model: model) }
            },
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
            hostName: { [model] in model.hosts.label($0) },
            // A card in the chat opens its file in Files, as the agent's call did (#836).
            showFile: { [model, frame, states, agent, popped] file in
                guard let agent else { return }
                model.work.rememberChart(file)
                // No Files pane in a window of its own: the file opens in the editor (#826).
                if popped != nil { return model.open(file.url, on: agent.host) }
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
            })
    }

    /// The sandbox card's answer for the open agent (064).
    private func sandboxAnswer(carryOn: Bool) -> (@MainActor () async -> Void)? {
        guard let id = agent?.id, agent?.pendingSandboxFailure != nil else { return nil }
        let model = model
        return { await model.answerSandbox(id, carryOn: carryOn) }
    }

    /// What can be done to the chat as a whole, at the right-hand edge of its column.
    @ViewBuilder
    private func actions(for agent: Agent) -> some View {
        if agent.missingFolder != nil, agent.state != .archived {
            MissingFolderStrip(agent: agent)
        } else if agent.state == .archived {
            // Matching the phone: an archived chat's own page is where Bring Back lives,
            // not only on the row you left it from.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button {
                    Task { await model.unarchive(agent.id) }
                } label: {
                    Label("Bring Back", systemImage: "tray.and.arrow.up")
                }
                .buttonStyle(.paper)
                .appText(.fine)
                .help("Bring this session back from the archive (⌥⌘⌫)")
            }
            .chatColumn()
            .padding(.vertical, 8)
        } else if model.isBlocked(agent) {
            // Stop is the prompt's own button while the agent works; Archive is on the
            // session's row and in the toolbar. What is left here is only what the page
            // has to say: what a blocked one waits on and the way on (039). An ask to be
            // archived is a card at the end of the transcript (#827).
            HStack(alignment: .top, spacing: 8) {
                // What it waits on, as its row says it (#341).
                WaitLines(lines: model.blockLines(agent))
                Spacer(minLength: 0)
                // What the card's Carry on does.
                Button {
                    Task { await model.carryOn(agent.id) }
                } label: {
                    Label(AgentsModel.carryOnLabel, systemImage: "play.circle")
                }
                .buttonStyle(.paper)
                .appText(.fine)
                .help(AgentsModel.carryOnHelp(for: agent))
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

    /// What waits on the person, each where it was asked in the transcript (#723, #973):
    /// none when nothing does, so the transcript has no way back to a question to offer.
    private var cards: [WaitingCard] {
        guard let agent else { return [] }
        var cards: [WaitingCard] = []
        for request in model.work.permissions(for: agent.id) {
            cards.append(WaitingCard(id: request.id.uuidString, at: request.askedAt) {
                PermissionView(request: request)
                    .disabled(selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // A change its agent made to the project's own files waits the same way (#531).
        for change in model.work.guardedChanges(askedIn: agent.id) {
            cards.append(WaitingCard(id: "guarded:" + change.id, at: change.since) {
                GuardedChangeQuestion(change: change, key: ProjectKey(host: agent.host, folder: agent.projectFolder))
                    .chatColumn()
            })
        }
        // A form waits the same way a permission question does.
        if let request = model.work.elicitation(for: agent.id) {
            cards.append(WaitingCard(id: request.id.uuidString, at: request.askedAt) {
                // A fresh card per form, so the answers and the step reached on one
                // are not carried into the next.
                ElicitationView(request: request)
                    .id(request.id)
                    .disabled(selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        // An ask to be archived waits the same way, last when asked at once (#827).
        if agent.asksToArchive {
            cards.append(WaitingCard(id: "archive:" + agent.id.uuidString,
                                     at: agent.archiveRequest?.requestedAt ?? .distantFuture) {
                ArchiveRequestCard(agent: agent,
                                   approve: { await model.archive(agent.id, andLeave: true) },
                                   keep: { await model.keepSession(agent) },
                                   isDisabled: selectedHostOffline || model.acting(agent.id) != nil)
                    .chatColumn()
                    .help(selectedHostOffline ? offlineHelp : "")
            })
        }
        return cards
    }

    private var form: some View {
        PromptBar()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
    }
}
