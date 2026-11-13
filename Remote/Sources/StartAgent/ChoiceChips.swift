import AgentsKitCore
import SwiftUI

/// Which runtime, and what it offers: the Mac's start controls, as chips in the prompt
/// card (029, #4556).
///
/// In the Mac's order: where, runtime, account, model, permission mode, sandbox, and ⋯
/// for the rest. They wrap into rows rather than scroll sideways, so none is past the
/// edge, and they sit above the words, so with the keyboard up they are in view. Each
/// chip reads its value and opens the menu its row opened. A runtime that cannot start is
/// still listed, with why, because one that silently is not there reads as one the phone
/// forgot.
struct ChoiceChips: View {
    @Environment(RemoteModel.self) private var model
    /// The session's labels, after ⋯ as tags (#2649).
    let labels: [String]
    /// Opens More; true to open it at Labels.
    let more: (_ atLabels: Bool) -> Void
    @State private var confirmingBypass = false

    var body: some View {
        WrappingHStack(spacing: 6) {
            if model.startWorktrees.isRepository {
                worktreeChip
            }
            runtimeChip
            // Which of the runtime's accounts (#840): only when it has more than one.
            if !model.startAccounts.isEmpty {
                accountChip
            }
            // The values in the shared words (#2658, Story 6).
            modelChip
            permissionModeChip
            sandboxChip
            moreChip
            ForEach(labels, id: \.self) { label in
                Button { more(true) } label: {
                    StartChip(title: label, chevron: false, plain: true)
                }
                .accessibilityLabel("Label, \(label)")
                .accessibilityHint("Opens More at Labels")
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        // Bypass Permissions: one more tap, as the pill asks (#2892).
        .confirmationDialog(LevelWords.bypassConfirmTitle, isPresented: $confirmingBypass, titleVisibility: .visible) {
            Button(LevelWords.bypassConfirmButton, role: .destructive) {
                model.chooseStartLevel(.permission, PermissionLevel.bypassPermissions.rawValue)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(LevelWords.bypassConfirmMessage)
        }
    }

    /// How many of More's choices are set (#4556): the runtime's own options away from
    /// their default, the Reach folders, the labels, and Permission requests set for this
    /// session.
    static func moreCount(_ model: RemoteModel, labels: [String]) -> Int {
        let own = model.isAutoStart ? 0 : model.startOptions.filter { option in
            guard let chosen = model.startChosen[option.id] else { return false }
            return chosen != option.currentValue
        }.count
        return own + model.startFolders.count + labels.count + (model.startClientPermission == nil ? 0 : 1)
    }

    private var moreChip: some View {
        let count = Self.moreCount(model, labels: labels)
        return Button { more(false) } label: {
            StartChip(title: nil, systemImage: "ellipsis", chevron: false, badge: count)
        }
        // Not "More": the page's own ⋯ in the navigation bar is called that.
        .accessibilityLabel("More choices")
        .accessibilityValue(count == 0 ? "" : "\(count) set")
        .accessibilityHint("The runtime's own options, Permission requests, Reach and Labels")
    }

    /// The runtime Auto picks now, by name.
    private var autoPicked: String? {
        model.startAutoPreview?.runtimeID.map(PromptWords.runtimeName)
    }

    /// The runtime each value is said on: the one chosen, or the one Auto picks now.
    private var mappedRuntime: String? {
        model.isAutoStart ? model.startAutoPreview?.runtimeID : model.startRuntimeID
    }

    /// Model: Fast, Balanced, Smart, each with what it is on the runtime (Story 6); the
    /// runtime's own setting that matches none reads Custom.
    private var modelChip: some View {
        let chosen = model.startLevel(.model)
        // Custom says which field it is: two chips reading Custom are two chips alike.
        let title = chosen.map { LevelWords.level(.model, $0) } ?? "\(LevelWords.modelField) · \(LevelWords.custom)"
        return Menu {
            ForEach(LevelWords.levels(.model), id: \.self) { level in
                Button {
                    model.chooseStartLevel(.model, level)
                } label: {
                    choiceLabel(LevelWords.level(.model, level), chosen: level == chosen)
                    Text(levelLine(.model, level))
                }
            }
            if chosen == nil {
                Section { Text(levelLine(.model, nil)) }
            }
        } label: {
            StartChip(title: title)
        }
        .accessibilityLabel("\(LevelWords.modelField), \(chosen.map { LevelWords.level(.model, $0) } ?? LevelWords.custom)")
    }

    private var permissionModeChip: some View {
        let chosen = model.startLevel(.permission)
        let title = chosen.map { LevelWords.level(.permission, $0) } ?? "\(LevelWords.permissionField) · \(LevelWords.custom)"
        return Menu {
            ForEach(LevelWords.levels(.permission), id: \.self) { level in
                let cell = mappedRuntime.flatMap { model.autoMappings.cell($0, .permission, level) }
                Button {
                    if LevelWords.asksFirst(.permission, level), level != chosen {
                        confirmingBypass = true
                    } else {
                        model.chooseStartLevel(.permission, level)
                    }
                } label: {
                    choiceLabel(LevelWords.level(.permission, level), chosen: level == chosen)
                    Text(cell.map { "\($0.words) on \(PromptWords.runtimeName($0.runtimeID))" }
                         ?? LevelWords.meaning(permission: PermissionLevel(rawValue: level) ?? .ask))
                }
                .disabled(cell.map { $0.mark == .notPossible || $0.mark == .dropped } ?? false)
            }
        } label: {
            StartChip(title: title)
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

    /// "Auto · Claude" on Auto, as the chat's header says it (#4556), else the runtime's name.
    private var runtimeTitle: String {
        if model.isAutoStart {
            if model.startAutoPicksNothing { return "\(LevelWords.auto) · no runtime" }
            return autoPicked.map(LevelWords.header) ?? LevelWords.auto
        }
        return model.startRuntime?.runtime.name ?? "None set up on \(model.startHost == .mac ? "the Mac" : model.hostName(model.startHost))"
    }

    /// The mark on the Runtime chip: red when Auto picks nothing (#2658), orange (a warning) when the
    /// runtime chosen is out (052, 065).
    private var runtimeDot: StateTint {
        if model.startAutoPicksNothing { return .failure }
        if model.startRuntimeOut != nil { return .warning }
        return .none
    }

    private var runtimeChip: some View {
        Menu {
            // Auto first (#2658): the Mac picks the runtime when the session starts.
            Button {
                Task { await model.chooseRuntime(LevelWords.autoID) }
            } label: {
                choiceLabel(LevelWords.auto, chosen: model.isAutoStart)
                Text(LevelWords.picks(autoPicked))
            }
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
            StartChip(title: runtimeTitle, dot: runtimeDot)
        }
        .disabled(model.startRuntimes.isEmpty)
        .accessibilityLabel("Runtime, \(runtimeTitle)")
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
    private var accountChip: some View {
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
            StartChip(title: name, locked: choices?.ownSetBy != nil)
        }
        .accessibilityLabel("Account, \(name)")
    }

    @ViewBuilder
    private func runtimeButtons(in runtimes: [RuntimeStatus], out: Bool = false) -> some View {
        ForEach(runtimes) { status in
            Button {
                Task { await model.chooseRuntime(status.runtime.id) }
            } label: {
                choiceLabel(status.runtime.name, chosen: status.runtime.id == model.startRuntimeID)
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
        guard model.startSplitsByAllowance else { return nil }
        if out { return outNote(status.runtime.id) }
        return availableNote(status.runtime.id) ?? model.signInNote(for: status.runtime.id)
    }

    /// The runtimes in two runs, as the Mac's chooser draws them (065): those that can
    /// take a turn now, and those whose plan is spent. An out runtime stays listed and
    /// stays pickable, because a chat on it takes the message and the runtime says no
    /// until its plan is back, and hiding it would hide the only way back to it.
    private var availableRuntimes: [RuntimeStatus] {
        guard model.startSplitsByAllowance else { return model.startRuntimes }
        return model.startRuntimes.filter { !isOut($0.id) }
    }

    private var outRuntimes: [RuntimeStatus] {
        guard model.startSplitsByAllowance else { return [] }
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
    private var worktreeChip: some View {
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
            // A worktree's name is cut at the end; the menu shows the whole of it (#2659).
            StartChip(title: worktreeTitle, systemImage: "arrow.triangle.branch", maxTitleWidth: 140)
        }
        .accessibilityLabel("Worktree, \(worktreeTitle)")
    }

    /// The new agent's command sandbox (064): its own choice, or its runtime's default.
    /// A runtime with no choice says its state, with why.
    @ViewBuilder
    private var sandboxChip: some View {
        if model.isAutoStart {
            // On Auto, the three values, each said as it is on the runtime Auto picks now.
            let chosen = model.startSandbox ?? .runtime
            // While the organisation requires the sandbox, only On is in force (#998, #2891).
            let setBy = model.sandboxSettings.setBy
            Menu {
                ForEach(SandboxChoice.allCases, id: \.self) { choice in
                    let cell = mappedRuntime.flatMap { model.autoMappings.cell($0, .sandbox, choice.rawValue) }
                    if let setBy, choice != .on {
                        OrgPolicyMenuItem(name: LevelWords.sandbox(choice), mark: setBy)
                    } else {
                        Button {
                            model.chooseStartLevel(.sandbox, choice.rawValue)
                        } label: {
                            choiceLabel(LevelWords.sandbox(choice), chosen: chosen == choice)
                            Text(cell.map { "\($0.words) on \(PromptWords.runtimeName($0.runtimeID))" } ?? LevelWords.meaning(sandbox: choice))
                        }
                    }
                }
            } label: {
                StartChip(title: LevelWords.sandbox(chosen), locked: setBy != nil)
            }
            .accessibilityLabel("\(LevelWords.sandboxField), \(LevelWords.sandbox(chosen))")
        } else if let runtimeID = model.startRuntimeID {
            let choices = SandboxCatalog.choices(for: runtimeID)
            let runtimeDefault = model.sandboxSettings.choice(for: runtimeID)
            let title = SandboxWords.override(model.startSandbox, runtimeDefault: runtimeDefault, runtimeID: runtimeID)
            if choices.isEmpty {
                // Its fixed value, in the shared words (#2658): said, not offered. With no
                // sandbox the app can vouch for, the organisation's rule refuses it (#998),
                // which the line over the card says.
                let none = SandboxCatalog.state(runtimeID: runtimeID, choice: .runtime) == SandboxState.none
                let fixed = LevelWords.sandbox(none ? .off : .runtime)
                StartChip(title: fixed, chevron: false, locked: model.sandboxSettings.setBy != nil)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(LevelWords.sandboxField), \(fixed)")
                    .accessibilityHint(SandboxCatalog.entry(for: runtimeID)?.why ?? "")
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
                    StartChip(title: title, locked: setBy != nil)
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
}

/// One chip in the prompt card (#4556): a raised paper capsule, 32 pt tall, that reads
/// its value, with a chevron when it opens a menu (`SelectCapsule`'s look).
struct StartChip: View {
    let title: String?
    var systemImage: String?
    var chevron = true
    /// A mark at its corner: red when it cannot start, orange when it needs a look.
    var dot: StateTint = .none
    /// Set by the organisation (#998): the menu still opens, with the refused values dimmed.
    var locked = false
    /// A count in the accent colour, for ⋯ (#4556).
    var badge = 0
    /// Cut at the end past this width, as a worktree's name is.
    var maxTitleWidth: CGFloat?
    /// A label's tag: grey, with no raised paper.
    var plain = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    // Decorative: the chip's words say what it is (FR-015).
                    .glyph(size: 11, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            if let title {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: maxTitleWidth, alignment: .leading)
            }
            if locked {
                Image(systemName: "lock.fill")
                    .glyph(size: 8, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
            if badge > 0 {
                Text("\(badge)")
                    .appText(.fine).fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Paper.accent, in: Capsule())
            }
            if chevron {
                Image(systemName: "chevron.down")
                    .glyph(size: 8, weight: .semibold)
                    .foregroundStyle(.secondary)
            }
        }
        .appText(.fine)
        .foregroundStyle(plain ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
        .contentShape(Capsule())
        .background { if plain { Capsule().fill(Paper.wash) } }
        .modifier(RaisedUnlessPlain(plain: plain))
        .overlay(alignment: .topTrailing) {
            if let color = dot.color {
                Circle().fill(color)
                    .frame(width: 8, height: 8)
                    .offset(x: -2, y: 2)
                    .accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: maxTitleWidth == nil, vertical: true)
    }
}

private struct RaisedUnlessPlain: ViewModifier {
    let plain: Bool

    func body(content: Content) -> some View {
        if plain { content } else { content.paperRaised(in: .capsule) }
    }
}
