import AgentsKitCore
import SwiftUI

/// The plan page (#5053, `specs/5048-first-build/spec.md`, sections 4 to 7): after Submit on
/// the question page, the whole window, still with no sidebar or toolbar. The idea as its
/// title, the starter under it, the starter's task list with each task's state, and under the
/// list the first-build session's chat. **Open Agents** takes it to the usual window.
///
/// The first two tasks are the window's: it sets up the runtime and connects GitHub inline,
/// then starts the agent with `firstBuild/start`. The agent's tasks are its plan, matched by
/// their words. The page is a view of the session, not a record of its own.
struct FirstBuildPlanView: View {
    @Environment(AppModel.self) private var model
    @State private var signingIn: String?
    @State private var connectingGitHub = false

    private var agent: Agent? { model.firstBuildAgent }
    private var facts: FirstBuild.Facts { model.firstBuildFacts }

    var body: some View {
        VStack(spacing: 0) {
            plan
                .frame(maxWidth: 640)
                .padding(.horizontal, 40)
                .padding(.top, 16)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
            Divider()
            chat
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 560)
        .paperGround()
        .overlay(alignment: .topTrailing) {
            Button("Open Agents") { model.openAgentsFromFirstBuild() }
                .buttonStyle(.paper)
                .help("The usual window, with this session selected")
                .padding(16)
        }
        .task {
            await model.refreshRuntimes()
            if let id = agent?.id, model.selection != id { model.selection = id }
        }
        // The GitHub task is ticked from the connector: from this page's sheet, or another
        // client. Read again every few seconds until it is connected.
        .task {
            while !Task.isCancelled {
                await model.refreshFirstBuildGitHub()
                if model.firstBuildGitHubConnected { return }
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // The agent starts once the window's tasks are done and a starter is chosen.
        .task(id: StartKey(facts: facts, starter: model.firstBuildStarter, runtime: model.firstBuildRuntimeID)) {
            await model.startFirstBuildIfReady()
        }
        // A runtime installing or signed in elsewhere: read the list again while it is not ready.
        .task(id: facts.runtimeReady) {
            while !facts.runtimeReady, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await model.refreshRuntimes()
            }
        }
        .onChange(of: agent?.id) { _, id in
            if let id, model.selection != id { model.selection = id }
        }
        .sheet(isPresented: Binding(get: { signingIn != nil }, set: { if !$0 { signingIn = nil } })) {
            if let signingIn {
                RuntimeAccountView(runtimeID: signingIn).paperSheet()
            }
        }
        .sheet(isPresented: $connectingGitHub) {
            ConnectGitHubSheet(host: .mac, onConnected: { Task { await model.refreshFirstBuildGitHub() } })
                .paperSheet()
        }
    }

    private struct StartKey: Equatable {
        var facts: FirstBuild.Facts
        var starter: FirstBuild.Starter?
        var runtime: String
    }

    // MARK: What will be built

    private var plan: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(model.firstBuildIdea ?? "")
                    .appText(.title).fontWeight(.semibold)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    // Room for Open Agents, at the top right.
                    .padding(.trailing, 110)
                starterLine
            }
            if let starter = model.firstBuildStarter {
                tasks(starter)
                startLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var starterLine: some View {
        if let starter = model.firstBuildStarter {
            HStack(spacing: 8) {
                Text(FirstBuild.starterLine(starter))
                    .appText(.reading).foregroundStyle(.secondary)
                if agent == nil {
                    Menu("Change") {
                        ForEach(FirstBuild.Starter.allCases, id: \.self) { other in
                            Button(FirstBuild.kindName(other)) { model.chooseFirstBuildStarter(other) }
                                .disabled(other == starter)
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.paper)
                    .fixedSize()
                    .help("Build the idea on the other starter")
                }
            }
        } else {
            chooseStarter
        }
    }

    /// Words that named no starter, or one neither starter makes (sections 3 and 4).
    private var chooseStarter: some View {
        let neither = FirstBuild.starter(for: model.firstBuildIdea ?? "") == .neither
        return VStack(alignment: .leading, spacing: 10) {
            Text(neither ? FirstBuild.neitherLine : "What kind of app is it?")
                .appText(.reading).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(FirstBuild.Starter.allCases, id: \.self) { starter in
                    Button(FirstBuild.kindName(starter)) { model.chooseFirstBuildStarter(starter) }
                        .buttonStyle(.paper)
                }
                if neither {
                    Button("Back") { model.backToFirstBuildQuestion() }
                        .buttonStyle(.paper)
                        .help("Change your idea")
                }
            }
        }
    }

    // MARK: The task list

    private func tasks(_ starter: FirstBuild.Starter) -> some View {
        let list = FirstBuild.tasks(for: starter)
        let states = FirstBuild.states(starter, facts)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(zip(list, states)), id: \.0.id) { task, state in
                FirstBuildTaskRow(task: task, state: state) { control(for: task) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paperRaised(in: RoundedRectangle(cornerRadius: Paper.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tasks")
    }

    /// The window's two tasks show their control inline while they are not done.
    @ViewBuilder
    private func control(for task: FirstBuild.PlanTask) -> some View {
        switch task.words {
        case FirstBuild.runtimeTask where !facts.runtimeReady:
            runtimeControl
        case FirstBuild.githubTask where !facts.githubConnected:
            Button("Connect GitHub…") { connectingGitHub = true }
                .buttonStyle(.paper)
        default:
            EmptyView()
        }
    }

    /// Claude by default, with the other runtimes in a menu beside it.
    @ViewBuilder
    private var runtimeControl: some View {
        if let runtime = model.firstBuildRuntime {
            HStack(spacing: 8) {
                Text(runtime.runtime.name).fontWeight(.medium)
                Text(runtime.machineLine).appText(.supporting).foregroundStyle(.secondary).lineLimit(1)
                if case .needsSignIn = runtime.availability {
                    Button("Sign In…") { signingIn = runtime.id }.buttonStyle(.paper)
                }
                if runtime.availability.isInstalling {
                    ProgressView().controlSize(.small)
                } else if runtime.offersInstall {
                    Button("Install") { Task { await model.installRuntime(runtime.id) } }
                        .buttonStyle(.paper)
                }
                Menu("Other Runtime") {
                    ForEach(model.runtimes) { other in
                        Button(other.runtime.name) { model.firstBuildRuntimeID = other.id }
                            .disabled(other.id == runtime.id)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.paper)
                .fixedSize()
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Looking for agent runtimes on this Mac…").appText(.supporting).foregroundStyle(.secondary)
            }
        }
    }

    /// Under the list: why the agent has not started yet, that it is starting, or why it did not.
    @ViewBuilder
    private var startLine: some View {
        if agent == nil {
            if let problem = model.firstBuildProblem {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label(problem, icon: "exclamationmark.triangle")
                        .appText(.supporting)
                        .tinted(.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Try Again") { Task { await model.retryFirstBuildStart() } }
                }
            } else if model.firstBuildStarting || FirstBuild.canStart(facts) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Starting the agent…").appText(.supporting).foregroundStyle(.secondary)
                }
            } else {
                Text("The agent starts when the first two tasks are done.")
                    .appText(.supporting).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: The agent's chat

    @ViewBuilder
    private var chat: some View {
        if let agent, model.selectedAgent?.id == agent.id {
            ChatView()
        } else {
            Text("The agent's chat shows here when it starts.")
                .appText(.supporting).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// One task and its state: to do, doing (a spinner), done (a tick), or waits for you (the
/// attention tint).
struct FirstBuildTaskRow<Control: View>: View {
    let task: FirstBuild.PlanTask
    let state: FirstBuild.TaskState
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            icon
                .frame(width: 16, height: 16)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.words)
                        .appText(.reading)
                        .foregroundStyle(state == .done ? .secondary : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityValue(stateWords)
                    if state == .waitsForYou {
                        Text("Waits for you")
                            .appText(.supporting).fontWeight(.medium)
                            .tinted(.attention)
                    }
                }
                if state != .done { control() }
            }
            Spacer(minLength: 0)
        }
        // Its control stays a control of its own, not part of the row's words.
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var icon: some View {
        switch state {
        case .toDo:
            Image(icon: "circle").glyph(size: 14).foregroundStyle(.tertiary).accessibilityHidden(true)
        case .doing:
            SyncedSpinner(diameter: 12).accessibilityHidden(true)
        case .done:
            Image(icon: "checkmark.circle.fill").glyph(size: 14).foregroundStyle(Paper.accent).accessibilityHidden(true)
        case .waitsForYou:
            Image(icon: "exclamationmark.circle.fill").glyph(size: 14).tinted(.attention).accessibilityHidden(true)
        }
    }

    private var stateWords: String {
        switch state {
        case .toDo: "To do"
        case .doing: "Doing"
        case .done: "Done"
        case .waitsForYou: "Waits for you"
        }
    }
}
