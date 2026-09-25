import AgentsKitCore
import SwiftUI

/// Which runtime, and what it offers: the Mac's start controls, as rows (029).
///
/// Only what the runtime advertises is drawn, in the order the Mac draws it
/// (`PromptControlsState.drawable`), and each row names what it chooses. A runtime that
/// cannot start is still listed, with why, because one that silently is not there reads
/// as one the phone forgot.
struct ChoiceRows: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        Section {
            runtimeRow
            if model.startWorktrees.isRepository {
                worktreeRow
            }
        }
        .paperListRow()
        Section {
            switch model.startChoicesState {
            case .loading:
                Label("Asking \(runtimeName) what it offers…", systemImage: "hourglass")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason).appText(.supporting).tinted(.failure)
                    Button("Try again") { Task { await model.loadStartChoices() } }
                        .appText(.supporting)
                        .accessibilityHint("Asks \(runtimeName) again what it offers")
                }
            case .ready:
                if model.startOptions.isEmpty {
                    Text("\(runtimeName) has nothing to adjust.")
                        .appText(.supporting)
                        .foregroundStyle(.secondary)
                }
                ForEach(model.startOptions, id: \.id) { option in
                    row(for: option)
                }
            }
        } footer: {
            if case .failed = model.startChoicesState, model.startRuntimeID != nil {
                Text("You can still start it with what \(runtimeName) chooses by itself.")
            }
        }
        .paperListRow()
    }

    private var runtimeName: String {
        model.startRuntime?.runtime.name ?? PromptControlsState.unnamedRuntime
    }

    private var runtimeRow: some View {
        Menu {
            ForEach(model.runtimes) { status in
                Button {
                    Task { await model.chooseRuntime(status.runtime.id) }
                } label: {
                    Text(status.runtime.name)
                    if let reason = status.unavailableReason { Text(reason) }
                }
                .disabled(!status.availability.isAvailable)
            }
        } label: {
            LabeledContent("Runtime") {
                Text(model.startRuntime?.runtime.name ?? "None set up on the Mac")
                    .foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .disabled(model.runtimes.isEmpty)
        .accessibilityLabel("Runtime, \(model.startRuntime?.runtime.name ?? "none")")
    }

    /// Project folder, a new worktree, or one already there (030), as the Mac's start
    /// bar offers them. Only on a repository.
    private var worktreeRow: some View {
        let listed = model.startWorktrees
        let others = listed.worktrees.filter { !$0.isProjectFolder }
        return Menu {
            Button {
                Task { await model.chooseWorktree(nil) }
            } label: {
                choiceLabel("Project folder", chosen: model.startWorktree == nil)
                Text(listed.projectFolderDescription)
            }
            Button {
                Task { await model.chooseWorktree(.new) }
            } label: {
                choiceLabel("New worktree", chosen: model.startWorktree == .new)
                Text(listed.canMakeNew ? "A new branch from the last commit here" : (listed.whyNot ?? ""))
            }
            .disabled(!listed.canMakeNew)
            if !others.isEmpty {
                Divider()
                ForEach(others) { worktree in
                    Button {
                        Task { await model.chooseWorktree(.existing(worktree.root)) }
                    } label: {
                        choiceLabel(worktree.name, chosen: model.startWorktree == .existing(worktree.root))
                        Text(Self.worktreeDetail(worktree))
                    }
                    .disabled(!worktree.exists)
                }
            }
            if !listed.branches.isEmpty {
                Divider()
                Menu("New worktree on a branch") {
                    ForEach(listed.branches) { branch in
                        Button {
                            Task { await model.chooseWorktree(.branch(branch.name)) }
                        } label: {
                            choiceLabel(branch.name, chosen: model.startWorktree == .branch(branch.name))
                            if let remote = branch.remote { Text("From \(remote)") }
                        }
                    }
                }
            }
        } label: {
            LabeledContent("Worktree") {
                Text(worktreeTitle).foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .accessibilityLabel("Worktree, \(worktreeTitle)")
    }

    private var worktreeTitle: String {
        switch model.startWorktree {
        case nil: "Project folder"
        case .new: "New worktree"
        case .existing(let root): root.lastPathComponent
        case .branch(let name): name
        }
    }

    @ViewBuilder
    private func choiceLabel(_ title: String, chosen: Bool) -> some View {
        if chosen { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Its branch and who is in it, as the Mac says it.
    static func worktreeDetail(_ worktree: DaemonAPI.WorktreeSummary) -> String {
        guard worktree.exists else { return "Missing" }
        let branch = worktree.branch ?? "detached"
        switch worktree.agents.count {
        case 0: return branch
        case 1: return "\(branch) · 1 agent working"
        case let count: return "\(branch) · \(count) agents working"
        }
    }

    @ViewBuilder
    private func row(for option: ConfigOption) -> some View {
        if option.isBoolean {
            Toggle(option.name, isOn: Binding(
                get: { model.startChosen[option.id]?.boolValue ?? option.currentValue?.boolValue ?? false },
                set: { model.choose(.bool($0), for: option.id) }))
                .appText(.reading)
        } else {
            let chosen = model.startChosen[option.id]
            Menu {
                ForEach(option.options ?? [], id: \.id) { choice in
                    Button {
                        model.choose(choice.value, for: option.id)
                    } label: {
                        if choice.value == chosen {
                            Label(choice.name, systemImage: "checkmark")
                        } else {
                            Text(choice.name)
                        }
                        if let description = choice.description { Text(description) }
                    }
                }
            } label: {
                LabeledContent(option.name) {
                    Text(option.closedTitle(for: chosen)).foregroundStyle(.secondary)
                }
                .appText(.reading)
            }
            .accessibilityLabel("\(option.name), \(option.closedTitle(for: chosen))")
        }
    }
}
