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
    @State private var confirmingAlwaysApprove = false

    var body: some View {
        Section {
            runtimeRow
            // The values in the shared words (#2658, Story 6).
            modelRow
            permissionModeRow
            permissionRow
            // Which of the runtime's accounts (#840): only when it has more than one.
            if !model.startAccounts.isEmpty {
                accountRow
            }
            if model.startWorktrees.isRepository {
                worktreeRow
            }
            sandboxRow
        }
        .paperListRow()
        // The runtime's own choices, behind the shared ones (#2658).
        Section {
            switch model.startChoicesState {
            case .loading:
                Label("Asking \(runtimeName) what it offers…", systemImage: "hourglass")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason).appText(.supporting).tinted(.failure)
                    Button("Try again") { Task { await model.retryStartChoices() } }
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
        } header: {
            Text(LevelWords.own(runtimeName))
        } footer: {
            if case .failed = model.startChoicesState, model.startRuntimeID != nil {
                Text("You can still start it with what \(runtimeName) chooses by itself.")
            }
        }
        .paperListRow()
    }

    /// The runtime each value is said on: the one chosen.
    private var mappedRuntime: String? { model.startRuntimeID }

    /// Model: Fast, Balanced, Smart as a segmented control (Story 6); the runtime's own
    /// setting that matches none says Custom under it.
    private var modelRow: some View {
        let chosen = model.startLevel(.model)
        return VStack(alignment: .leading, spacing: 6) {
            Picker(LevelWords.modelField, selection: Binding(
                get: { chosen ?? "" },
                set: { model.chooseStartLevel(.model, $0) })) {
                ForEach(LevelWords.levels(.model), id: \.self) { level in
                    Text(LevelWords.level(.model, level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            Text(levelLine(.model, chosen))
                .appText(.supporting)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(LevelWords.modelField)
    }

    private var permissionModeRow: some View {
        let chosen = model.startLevel(.permission)
        return Menu {
            ForEach(LevelWords.levels(.permission), id: \.self) { level in
                let cell = mappedRuntime.flatMap { model.autoMappings.cell($0, .permission, level) }
                Button {
                    model.chooseStartLevel(.permission, level)
                } label: {
                    if level == chosen {
                        Label(LevelWords.level(.permission, level), systemImage: "checkmark")
                    } else {
                        Text(LevelWords.level(.permission, level))
                    }
                    Text(cell.map { "\($0.words) on \(PromptWords.runtimeName($0.runtimeID))" }
                         ?? LevelWords.meaning(permission: PermissionLevel(rawValue: level) ?? .ask))
                }
                .disabled(cell.map { $0.mark == .notPossible || $0.mark == .dropped } ?? false)
            }
        } label: {
            LabeledContent(LevelWords.permissionField) {
                Text(chosen.map { LevelWords.level(.permission, $0) } ?? LevelWords.custom).foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .accessibilityLabel("\(LevelWords.permissionField), \(chosen.map { LevelWords.level(.permission, $0) } ?? LevelWords.custom)")
    }

    /// "Sonnet on Claude" under the value, or Custom's meaning.
    private func levelLine(_ field: AutoField, _ chosen: String?) -> String {
        guard let chosen else { return "\(LevelWords.custom): \(runtimeName)’s own setting" }
        guard let runtimeID = mappedRuntime, let cell = model.autoMappings.cell(runtimeID, field, chosen) else {
            return LevelWords.meaning(model: ModelLevel(rawValue: chosen) ?? .balanced)
        }
        return "\(cell.words) on \(PromptWords.runtimeName(runtimeID))"
    }

    private var runtimeName: String {
        model.startRuntime?.runtime.name ?? PromptControlsState.unnamedRuntime
    }

    /// The runtime's name. The Auto runtime is Mac + web (#2798).
    private var runtimeTitle: String {
        return model.startRuntime?.runtime.name ?? "None set up on \(model.startHost == .mac ? "the Mac" : model.hostName(model.startHost))"
    }

    private var runtimeRow: some View {
        Menu {
            if !outRuntimes.isEmpty {
                Section("Available") {
                    runtimeButtons(in: availableRuntimes)
                }
                Section("Out") {
                    runtimeButtons(in: outRuntimes, out: true)
                }
            } else {
                runtimeButtons(in: model.startRuntimes)
            }
        } label: {
            LabeledContent(LevelWords.runtimeField) {
                Text(runtimeTitle)
                    .foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .disabled(model.startRuntimes.isEmpty)
        .accessibilityLabel("Runtime, \(runtimeTitle)")
    }

    /// The new agent's answer to permission requests (#2658, FR-019): its own, or the value
    /// Settings gives, marked; only for Cursor, Grok and OpenCode, and not on Auto, where it
    /// follows the permission mode.
    @ViewBuilder
    private var permissionRow: some View {
        if let runtimeID = model.startRuntimeID, ClientPermissionSettings.supports(runtimeID) {
            let name = model.startRuntime?.runtime.name ?? runtimeID
            let settings = model.clientPermissions.mode(for: runtimeID)
            let mode = model.startClientPermission ?? settings
            Menu {
                ForEach([ClientPermissionMode.default, .alwaysApprove], id: \.self) { choice in
                    Button {
                        if choice == .alwaysApprove, mode != .alwaysApprove {
                            confirmingAlwaysApprove = true
                        } else {
                            model.startClientPermission = model.startClientPermission == nil && choice == settings ? nil : choice
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            choiceLabel(ClientPermissionWords.title(choice), chosen: choice == mode)
                            Text(model.startClientPermission == nil && choice == settings
                                 ? "\(LevelWords.followsSettings). \(ClientPermissionWords.description(choice, runtimeName: name))"
                                 : ClientPermissionWords.description(choice, runtimeName: name))
                                .appText(.supporting)
                        }
                    }
                }
            } label: {
                LabeledContent(LevelWords.requestsField) {
                    Text(ClientPermissionWords.title(mode)).foregroundStyle(.secondary)
                }
                .appText(.reading)
            }
            .accessibilityLabel("\(ClientPermissionWords.name(runtimeName: name)), \(ClientPermissionWords.title(mode))")
            .accessibilityHint(ClientPermissionWords.scope(runtimeName: name))
            // Yes to all answers every request: one more tap, as the capsule asks (#2746).
            .confirmationDialog(ClientPermissionWords.confirmTitle(runtimeName: name),
                                isPresented: $confirmingAlwaysApprove, titleVisibility: .visible) {
                Button(ClientPermissionWords.confirmButton, role: .destructive) {
                    model.startClientPermission = settings == .alwaysApprove ? nil : .alwaysApprove
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(ClientPermissionWords.confirmMessage(runtimeName: name))
            }
        }
    }

    /// Under an account's name: why it cannot be used, or that its allowance is out, as the
    /// Mac's Account capsule says it (#2265).
    private func accountNote(_ account: AccountProfile?, choices: AccountChoices?) -> String? {
        guard let choices else { return nil }
        return AccountWords.choiceNote(account, row: model.runtimeAllowances?.row(choices.runtimeID, account: account?.id),
                                       now: model.runtimeAllowances?.at ?? Date())
    }

    /// Which of the runtime's accounts the session uses (#840), the organisation's included
    /// (#999). One the organisation's policy refuses is shown, not chosen.
    private var accountRow: some View {
        let choices = model.startAccountChoices
        let chosen = choices?.account(for: model.startAccountID)
        let name = choices?.name(model.startAccountID) ?? AccountProfile.defaultName
        return Menu {
            if let mark = choices?.ownSetBy {
                OrgPolicyMenuItem(name: AccountProfile.defaultName, mark: mark)
            } else {
                Button {
                    model.startAccountID = choices?.ownChoice
                } label: {
                    choiceLabel(AccountProfile.defaultName, chosen: chosen == nil)
                    if let note = accountNote(nil, choices: choices) { Text(note) }
                }
            }
            ForEach(choices?.accounts ?? []) { account in
                if let mark = account.setBy {
                    OrgPolicyMenuItem(name: account.name, mark: mark)
                } else {
                    Button {
                        model.startAccountID = account.id
                    } label: {
                        choiceLabel(account.name, chosen: chosen?.id == account.id)
                        Text(accountNote(account, choices: choices) ?? account.state)
                    }
                }
            }
        } label: {
            LabeledContent("Account") {
                Text(name).foregroundStyle(.secondary)
            }
            .appText(.reading)
        }
        .accessibilityLabel("Account, \(name)")
    }

    @ViewBuilder
    private func runtimeButtons(in runtimes: [RuntimeStatus], out: Bool = false) -> some View {
        ForEach(runtimes) { status in
            Button {
                Task { await model.chooseRuntime(status.runtime.id) }
            } label: {
                Text(status.runtime.name)
                if let detail = detail(for: status, out: out) { Text(detail) }
            }
            .disabled(!status.canStart)
        }
    }

    /// What is said under the name, and nothing more. Why it cannot start wins: that is
    /// the one thing a person needs before choosing. Otherwise what its allowance says,
    /// which is a reason in the out run and a throttle in the other, and in the
    /// available run with no throttle, whether it is signed in (#538), as the Mac says.
    private func detail(for status: RuntimeStatus, out: Bool) -> String? {
        if let reason = status.unavailableReason { return reason }
        // The allowances and accounts are the Mac's, and say nothing of a server's
        // runtime (#240).
        guard splitsByAllowance else { return nil }
        if out { return outNote(status.runtime.id) }
        return availableNote(status.runtime.id) ?? model.signInNote(for: status.runtime.id)
    }

    /// The runtimes in two runs, as the Mac's chooser draws them (065): those that can
    /// take a turn now, and those whose plan is spent. An out runtime stays listed and
    /// stays pickable, because a chat on it takes the message and the runtime says no
    /// until its plan is back, and hiding it would hide the only way back to it. Naming
    /// it as out is the whole of the change: a list of runtimes by name says nothing
    /// about which ones will turn a message down.
    ///
    /// A server folder's runtimes are left in one run, as the window leaves them (#240):
    /// the allowances are the Mac's own, and would label a server's runtime with the
    /// Mac's state.
    private var splitsByAllowance: Bool { model.startHost == .mac }

    private var availableRuntimes: [RuntimeStatus] {
        guard splitsByAllowance else { return model.startRuntimes }
        return model.startRuntimes.filter { !isOut($0.id) }
    }

    private var outRuntimes: [RuntimeStatus] {
        guard splitsByAllowance else { return [] }
        return model.startRuntimes.filter { isOut($0.id) }
    }

    private func isOut(_ runtimeID: String) -> Bool {
        model.runtimeAllowances?.isOut(runtimeID) == true
    }

    /// What is wrong with it, under the name, and which line of the Mac's own words.
    /// It says nothing about another runtime: there is no order to take one from.
    private func outNote(_ runtimeID: String) -> String? {
        model.runtimeAllowances?.note(for: runtimeID)
    }

    /// A rate limit is not an out runtime, and an available run that says nothing about
    /// one reads as no limit at all. Nor is a model out (#140), said the same way.
    private func availableNote(_ runtimeID: String) -> String? {
        model.runtimeAllowances?.availableNote(for: runtimeID)
    }

    /// Folder, a new worktree, or one already there (030), as the Mac's start
    /// bar offers them. Only on a repository.
    private var worktreeRow: some View {
        let listed = model.startWorktrees
        let others = listed.worktrees.filter { !$0.isFolderPath }
        return Menu {
            Button {
                Task { await model.chooseWorktree(nil) }
            } label: {
                choiceLabel("Folder", chosen: model.startWorktree == nil)
                Text(listed.folderPathDescription)
            }
            Button {
                Task { await model.chooseWorktree(.new) }
            } label: {
                choiceLabel("New worktree", chosen: model.startWorktree == .new)
                Text(listed.canMakeNew ? "A new branch from the last commit here" : (listed.whyNot ?? ""))
            }
            .disabled(!listed.canMakeNew)
            // The one a view named (#834), on one line: an issue's title is long (#2659).
            if case .named(let name) = model.startWorktree {
                Button {} label: {
                    choiceLabel("New worktree", chosen: true)
                    Text(name).lineLimit(1).truncationMode(.tail)
                }
            }
            if !others.isEmpty {
                Divider()
                ForEach(others) { worktree in
                    Button {
                        Task { await model.chooseWorktree(.existing(worktree.root)) }
                    } label: {
                        choiceLabel(worktree.name, chosen: model.startWorktree == .existing(worktree.root))
                        Text(Self.worktreeDetail(worktree, size: model.work.size(of: worktree,
                                                                                 on: model.selectedSummary?.host ?? .mac)))
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

    /// The new agent's command sandbox (064): its own choice, or its runtime's default.
    /// A runtime with no choice says its state, with why.
    @ViewBuilder
    private var sandboxRow: some View {
        if let runtimeID = model.startRuntimeID {
            let choices = SandboxCatalog.choices(for: runtimeID)
            let runtimeDefault = model.sandboxSettings.choice(for: runtimeID)
            let title = SandboxWords.override(model.startSandbox, runtimeDefault: runtimeDefault, runtimeID: runtimeID)
            if choices.isEmpty {
                LabeledContent(LevelWords.sandboxField) {
                    // Its fixed value, in the shared words (#2658).
                    let none = SandboxCatalog.state(runtimeID: runtimeID, choice: .runtime) == SandboxState.none
                    Text(LevelWords.sandbox(none ? .off : .runtime))
                        .foregroundStyle(.secondary)
                }
                .appText(.reading)
                .accessibilityHint(SandboxCatalog.entry(for: runtimeID)?.why ?? "")
                // No sandbox the app can vouch for, so the organisation's rule refuses it (#998).
                if let mark = model.sandboxSettings.setBy { OrgPolicyLine(mark: mark) }
            } else {
                // While the organisation requires the sandbox, only On is in force (#998).
                let setBy = model.sandboxSettings.setBy
                Menu {
                    ForEach(choices, id: \.self) { choice in
                        if let setBy, choice != .on {
                            OrgPolicyMenuItem(name: choice == .off ? SandboxWords.startWithout
                                                  : SandboxWords.choice(choice, runtimeID: runtimeID), mark: setBy)
                        } else {
                            Button {
                                // The value Settings gives, chosen again, follows Settings still.
                                model.startSandbox = model.startSandbox == nil && choice == runtimeDefault ? nil : choice
                                // Codex's sandbox is its mode (FR-005a).
                                if runtimeID == RuntimeCatalog.codex.id, choice == .off {
                                    model.choose("agent-full-access", for: "mode")
                                }
                            } label: {
                                choiceLabel(SandboxWords.choice(choice, runtimeID: runtimeID),
                                            chosen: (model.startSandbox ?? runtimeDefault) == choice)
                                if model.startSandbox == nil, choice == runtimeDefault {
                                    Text(LevelWords.followsSettings)
                                }
                                Text(SandboxWords.explanation(choice, runtimeID: runtimeID,
                                                              name: model.startRuntime?.runtime.name ?? runtimeID))
                            }
                        }
                    }
                } label: {
                    LabeledContent(LevelWords.sandboxField) {
                        Text(title).foregroundStyle(.secondary)
                    }
                    .appText(.reading)
                }
                .accessibilityLabel("Sandbox, \(title)")
            }
        }
    }

    private var worktreeTitle: String {
        switch model.startWorktree {
        case nil: "Folder"
        // A named one's name is long and is not what the daemon calls it (#2659): the menu shows it.
        case .new, .named: "New worktree"
        case .existing(let root): root.lastPathComponent
        case .branch(let name): name
        }
    }

    @ViewBuilder
    private func choiceLabel(_ title: String, chosen: Bool) -> some View {
        if chosen { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    /// Its branch, its git status and who is in it, as the Mac says it.
    /// Its branch, git status, who is in it, and with `size` how much it holds (#790).
    static func worktreeDetail(_ worktree: DaemonAPI.WorktreeSummary, size: DaemonAPI.WorktreeSize? = nil) -> String {
        guard worktree.exists else { return "Missing" }
        var parts = [worktree.branch ?? "detached"]
        if let status = worktree.status { parts.append(status.summary) }
        switch worktree.agents.count {
        case 0: break
        case 1: parts.append("1 agent working")
        case let count: parts.append("\(count) agents working")
        }
        if let size { parts.append(size.words) }
        return parts.joined(separator: " · ")
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
                    if let mark = choice.setBy {
                        // A mode or model the organisation refuses: shown, not chosen (#998).
                        OrgPolicyMenuItem(name: choice.name, mark: mark)
                    } else {
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
