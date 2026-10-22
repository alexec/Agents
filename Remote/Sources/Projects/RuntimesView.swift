import AgentsKitCore
import SwiftUI

/// Each runtime on the Mac and where its allowance stands (065, US4): out, since when,
/// when it is next checked, and what is left of its plan. The Mac's Agent Runtimes
/// words, as a list. Mark available is a swipe action.
/// An account added to a runtime (#840) is its own row; Add Account is in the toolbar and
/// Remove is a swipe. Signing one in is done on the Mac, in Runtimes (#2255). An org account (#999) is a row too,
/// which only the organisation removes, and a runtime with accounts has **Reaches the Model
/// By** under its own row.
struct RuntimesView: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        List {
            if let allowances = model.runtimeAllowances {
                ForEach(allowances.rows) { row in
                    VStack(alignment: .leading, spacing: 6) {
                        RuntimeAllowanceRow(row: row, at: allowances.at, setBy: setBy(of: row))
                        if row.accountID == nil, let choices = choices(of: row), choices.shows {
                            ReachesTheModelByMenu(choices: choices)
                        }
                    }
                        .swipeActions {
                            if row.state.isOut {
                                Button("Mark available") { Task { await model.markRuntimeAvailable(row.credentialKey) } }
                                    .tint(.gray)
                            }
                            if let account = account(of: row) {
                                Button("Remove", role: .destructive) { removing = account }
                            }
                        }
                }
            }
            // The person's own pass-through names on the Mac, a name the policy refuses dimmed (#998).
            if !model.passThrough.names.isEmpty {
                Section("Variables passed to runtimes") {
                    ForEach(model.passThrough.names) { name in
                        VStack(alignment: .leading, spacing: 2) {
                            PassThroughRows(names: [name])
                            if let runtime = name.runtime {
                                Text(OrgPolicyWords.runtimeName(runtime)).appText(.fine).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if model.accountProfiles.contains(where: { !$0.isOrganisation }) {
                Section {} footer: {
                    Text("Sign in to an added account on the Mac, in Runtimes.")
                }
            }
        }
        .toolbar {
            if !accountRuntimes.isEmpty {
                Menu {
                    ForEach(accountRuntimes) { status in
                        Button(status.runtime.name) {
                            newName = ""
                            addingTo = status.runtime
                        }
                    }
                } label: {
                    Label("Add Account", systemImage: "person.badge.plus")
                }
            }
        }
        .alert("Add a \(addingTo?.name ?? "") account", isPresented: Binding(get: { addingTo != nil },
                                                                           set: { if !$0 { addingTo = nil } })) {
            TextField("Name, such as Work", text: $newName)
            Button("Add") {
                guard let runtime = addingTo else { return }
                Task { addProblem = await model.addAccount(runtimeID: runtime.id, name: newName) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You choose it when you start a session. \(AccountWords.signInOnTheMac)")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let account = removing else { return }
                Task { await model.removeAccount(account) }
            }
        } message: {
            Text(AccountWords.removeMessage(stopping: removing.map(model.agentsHolding(account:))?.count ?? 0,
                                            from: "the Mac"))
        }
        .navigationTitle("Runtimes")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
        .markedStale(model.isStale)
        .overlay {
            if model.runtimeAllowances?.rows.isEmpty != false {
                Text("No runtimes on the Mac yet.").foregroundStyle(.secondary)
            }
        }
        .task {
            await model.refreshRuntimeAllowances()
            await model.refreshAccountProfiles()
            await model.refreshPassThrough()
        }
        .refreshable {
            await model.refreshRuntimeAllowances()
            await model.refreshAccountProfiles()
            await model.refreshPassThrough()
        }
        .alert("Not added", isPresented: Binding(get: { addProblem != nil }, set: { if !$0 { addProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addProblem ?? "")
        }
    }

    @State private var addingTo: Runtime?
    @State private var newName = ""
    @State private var removing: AccountProfile?
    @State private var addProblem: String?

    /// The Mac's runtimes that keep their sign-in in a folder, so take more than one account,
    /// and are on the Mac.
    private var accountRuntimes: [RuntimeStatus] {
        model.runtimes.filter { $0.runtime.accountFolderVariable != nil && !$0.availability.isMissing }
    }

    /// The organisation's mark when its policy does not allow the row's runtime (#998).
    private func setBy(of row: RuntimeAllowances.Row) -> DaemonAPI.PolicySetBy? {
        let runtimeID = row.credentialKey.split(separator: ":").first.map(String.init)
        return model.runtimes.first { $0.id == runtimeID }?.setBy
    }

    /// The account a row is for, when the person may remove it: not an org account.
    private func account(of row: RuntimeAllowances.Row) -> AccountProfile? {
        row.accountID.flatMap { id in model.accountProfiles.first { $0.id == id && !$0.isOrganisation } }
    }

    /// The accounts of the row's runtime, for **Reaches the Model By** (#999).
    private func choices(of row: RuntimeAllowances.Row) -> AccountChoices? {
        guard !row.credentialKey.contains(":account:") else { return nil }
        return AccountChoices(runtimeID: row.runtimeID, profiles: model.accountProfiles, policy: model.policyState?.policy)
    }
}

/// The runtime's account for new sessions (#999, spec FR-024), as the Mac's sign-in sheet
/// has it: a choice the organisation's policy refuses is shown, not chosen.
private struct ReachesTheModelByMenu: View {
    @Environment(RemoteModel.self) private var model
    let choices: AccountChoices
    @State private var problem: String?

    var body: some View {
        let current = choices.defaultAccount
        Menu {
            if let mark = choices.ownSetBy {
                OrgPolicyMenuItem(name: AccountProfile.defaultName, mark: mark)
            } else {
                Button { set(nil) } label: { label(AccountProfile.defaultName, chosen: current == nil) }
            }
            ForEach(choices.accounts) { account in
                if let mark = account.setBy {
                    OrgPolicyMenuItem(name: account.name, mark: mark)
                } else {
                    Button { set(account.id) } label: {
                        label(account.name, chosen: current?.id == account.id)
                        if account.isOrganisation { Text(account.state) }
                    }
                }
            }
        } label: {
            LabeledContent(OrgAccountWords.reachesTheModelBy) {
                Text(current?.name ?? AccountProfile.defaultName).foregroundStyle(.secondary)
            }
            .appText(.fine)
        }
        .accessibilityLabel("\(OrgAccountWords.reachesTheModelBy), \(current?.name ?? AccountProfile.defaultName)")
        .alert("Not changed", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    @ViewBuilder private func label(_ title: String, chosen: Bool) -> some View {
        if chosen { Label(title, systemImage: "checkmark") } else { Text(title) }
    }

    private func set(_ accountID: String?) {
        Task { problem = await model.setDefaultAccount(runtimeID: choices.runtimeID, accountID: accountID) }
    }
}

private struct RuntimeAllowanceRow: View {
    let row: RuntimeAllowances.Row
    let at: Date
    var setBy: DaemonAPI.PolicySetBy?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.title).fontWeight(.semibold)
                .foregroundStyle(setBy == nil ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            if let setBy { OrgPolicyLine(mark: setBy) }
            // An org account says where it is from (spec FR-023), never a key or an address.
            if row.isOrganisation {
                Text(OrgAccountWords.fromOrganisation).appText(.fine).foregroundStyle(.secondary)
            }
            Text(row.unusable.map { "Not usable: \($0)" } ?? row.memberLine(now: at))
                .appText(.fine)
                .foregroundStyle(row.state.isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
            if row.unusable == nil, let reading = PoolWords.reading(row.state.reading, now: at) {
                Text(reading).appText(.fine).foregroundStyle(.secondary)
                if let current = row.state.reading { AllowanceBar(reading: current) }
            }
            if let note = row.setupNote {
                Text(LocalizedStringKey(note)).appText(.fine).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// The link to it at the foot of Spending, with the Mac's red dot when a runtime is out.
struct RuntimesLink: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        NavigationLink { RuntimesView() } label: {
            HStack {
                Label("Runtimes", systemImage: "cpu")
                Spacer()
                if model.runtimeAllowances?.anyOut == true {
                    Circle().fill(StateTint.failure.style(or: .primary)).frame(width: 8, height: 8)
                        .accessibilityLabel("A runtime is out")
                }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
