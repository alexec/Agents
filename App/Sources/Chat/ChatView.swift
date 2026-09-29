import AgentsKit
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
/// agent said can still be scrolled clear of it.
struct ChatView: View {
    @Environment(AppModel.self) private var model
    @Environment(SidebarFrame.self) private var frame
    @Environment(SidebarStates.self) private var states
    @State private var formHeight: CGFloat = 0

    private var agent: Agent? { model.selectedAgent }

    var body: some View {
        Group {
            if let agent {
                ZStack(alignment: .bottom) {
                    Transcript(agent: agent, bottomInset: formHeight)
                        // What was exchanged, a swipe away, as on the phone.
                        .swipeToShowPane(show: {
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
                            }
                            // On the page's own paper, across the whole pane: the
                            // transcript scrolls under this strip, and without a ground
                            // of its own its words showed through between the buttons.
                            // Kept to the strip's own bounds: a colour's background fills
                            // the safe area too by default, which here is the transcript.
                            .frame(maxWidth: .infinity)
                            .background(Paper.ground, ignoresSafeAreaEdges: [])
                        }
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
        .animation(.snappy(duration: 0.28), value: model.selection)
        // Title stays on SessionsColumn: one owner for the window title.
        .environment(\.chatActions, chatActions)
    }

    /// What the shared chat rows mean on a Mac (033).
    private var chatActions: ChatActions {
        ChatActions(
            // The editor the Mac opens that file with, which is the one the user chose.
            open: { location in NSWorkspace.shared.open(URL(filePath: location.path)) },
            terminalOutput: { [model] id in model.terminalOutput[id] ?? "" },
            unqueue: { [model] prompt, agentID in await model.unqueue(prompt, from: agentID) },
            sendNow: { [model] prompt, agentID in await model.sendNow(prompt, to: agentID) },
            canSendNow: { [model] runtimeID in runtimeID.flatMap { model.accounts[$0]?.canSteer } ?? false },
            // The sidebar's Changes pane, open at that edit (035 FR-014).
            showEdit: { [frame, states, agent] diff, toolCallID in
                guard let agent else { return }
                states.state(for: agent.id).changesSelection = ChangesSelection(
                    path: ReportedChanges.key(diff.path), toolCallID: toolCallID)
                frame.pane = .changes
                if !frame.isOpen { frame.open() }
            },
            // The sidebar's Background pane, at that subagent (057, frame C).
            subagentSteps: { [frame, states, agent] id in
                guard let agent else { return }
                states.state(for: agent.id).subagent = id
                frame.pane = .background
                if !frame.isOpen { frame.open() }
            },
            backgroundOutput: { item in BackgroundOutput.open(item) },
            turnEntries: { [model] agentID, range in await model.turnEntries(agentID, range) },
            continueWithoutSandbox: sandboxAnswer(carryOn: true),
            keepStopped: sandboxAnswer(carryOn: false))
    }

    /// The sandbox card's answer for the open agent (064).
    private func sandboxAnswer(carryOn: Bool) -> (@MainActor () async -> Void)? {
        guard let id = agent?.id else { return nil }
        let model = model
        return { await model.answerSandbox(id, carryOn: carryOn) }
    }

    /// What can be done to the chat as a whole, at the right-hand edge of its column.
    @ViewBuilder
    private func actions(for agent: Agent) -> some View {
        if agent.state == .archived {
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
        } else if ParkWords.line(agent.parking) != nil || model.isBlocked(agent) {
            // Stop is the prompt's own button while the agent works; Park and Archive
            // are on the session's row. What is left here is only what the page has to
            // say: why a parked chat is parked, and the way on for a blocked one.
            HStack(spacing: 8) {
                // Said on the page, so a chat opened from Parked says why it is there
                // and when (040, FR-011).
                if let line = ParkWords.line(agent.parking) {
                    Label(line, systemImage: ParkWords.symbol)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                // A blocked chat (039): what the card's Carry on does.
                if model.isBlocked(agent) {
                    Button {
                        Task { await model.carryOn(agent.id) }
                    } label: {
                        Label(AgentsModel.carryOnLabel, systemImage: "play.circle")
                    }
                    .buttonStyle(.paper)
                    .appText(.fine)
                    .help(AgentsModel.carryOnHelp(for: agent))
                }
            }
            .chatColumn()
            .padding(.vertical, 8)
        }
    }

    private var selectedHostOffline: Bool {
        model.hosts.isOffline(model.selectedAgent?.host ?? .mac)
    }

    private var offlineHelp: String {
        "\(model.hosts.label(model.selectedAgent?.host ?? .mac)) is offline"
    }

    private var form: some View {
        VStack(spacing: 12) {
            if !model.permissionsForSelection.isEmpty {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.permissionsForSelection) { request in
                            PermissionView(request: request)
                                .disabled(selectedHostOffline)
                                .help(selectedHostOffline ? offlineHelp : "")
                        }
                    }
                }
                .frame(maxHeight: 300)
                .fixedSize(horizontal: false, vertical: true)
            }
            // A form waits the same way a permission question does, and floats with it.
            if let request = model.elicitationForSelection {
                // A fresh card per form, so the answers and the step reached on one
                // are not carried into the next.
                ElicitationView(request: request)
                    .id(request.id)
                    .disabled(selectedHostOffline)
                    .help(selectedHostOffline ? offlineHelp : "")
            }
            PromptBar()
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
    }
}
