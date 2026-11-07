import AgentsKitCore
import SwiftUI

/// Your setup (#3630, #3631): every runtime once, where its allowance stands, its accounts,
/// and a line per machine that says whether it is installed and signed in there, each to that
/// machine's page (#3626). The accounts and allowances are This Mac's, where accounts are added
/// and signed in (#2257); what a machine installs is on its page (#3629). It was Status ▸
/// Runtimes, drawn for one machine (065, US4).
///
/// A page like Resources, reached from the foot of the sidebar. It was in Settings ▸
/// Agent Runtimes, which is where a control belongs; what it says is the state of the
/// machine, and it changes without anybody touching a setting. Settings keeps what
/// changes the Mac: installing a runtime, its permission mode.
///
/// Every runtime the app knows is here, installed or not, so the page answers "what can
/// I start on, and how much is left" in one place (#3744): the runtimes installed somewhere
/// first, each in a short row with its detail closed, then the others under "Other runtimes",
/// closed. A runtime with no allowance of its own says so rather than
/// being left out, and one that is not on the Mac says what stopped it. **Mark available**
/// asks nothing first: a wrong mark costs one refused turn (FR-023).
///
/// The accounts of a runtime are here too (#2255), as the Remote and the web page send a person
/// here to sign one in: **Add Account…** on the runtime's row, **Sign In…** (the runtime's
/// sign-in sheet, which has the Accounts section) and **Remove…** on an account's row.
struct RuntimesView: View {
    @Environment(AppModel.self) private var model

    /// The runtime whose sign-in sheet is open.
    @State private var signingIn: String?
    @State private var addingTo: Runtime?
    @State private var newName = ""
    @State private var addProblem: String?
    @State private var removing: AccountProfile?
    /// The runtimes whose Details are open; all are closed when the page opens (#3744).
    @State private var expanded: Set<String> = []
    @State private var showsOthers = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Runtimes").appText(.reading)
                // One sentence (#3744); what a spent allowance means is its help tag.
                Text("What you can start on, and how much is left.")
                    .appText(.supporting)
                    .foregroundStyle(.secondary)
                    .help("An allowance that is spent is not a fault: a chat on it still takes a message, "
                          + "and the runtime says no until its plan comes back.")
                if !inUse.isEmpty { runtimeList(inUse) }
                if !others.isEmpty {
                    DisclosureGroup("Other runtimes (\(others.count))", isExpanded: $showsOthers) {
                        runtimeList(others).padding(.top, 8)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("Runtimes")
        .overlay {
            if runtimes.isEmpty {
                Text("No runtimes known yet.")
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            await model.refreshRuntimes()
            await model.refreshRuntimeAllowances()
            await model.refreshAccountProfiles()
            for host in model.hosts.servers where !model.hosts.isOffline(host) {
                await model.refreshServerRuntimes(host)
            }
        }
        .sheet(isPresented: Binding(get: { signingIn != nil }, set: { if !$0 { signingIn = nil } })) {
            if let signingIn {
                RuntimeAccountView(runtimeID: signingIn)
                    .paperSheet()
            }
        }
        .alert("Add a \(addingTo?.name ?? "") account", isPresented: Binding(get: { addingTo != nil },
                                                                           set: { if !$0 { addingTo = nil } })) {
            TextField("Name, such as Work", text: $newName)
            Button("Add") {
                guard let runtime = addingTo else { return }
                let name = newName.trimmingCharacters(in: .whitespaces)
                Task { addProblem = await model.addAccount(runtimeID: runtime.id, name: name) }
            }
            .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You choose it when you start a session. Then sign it in here.")
        }
        .alert("Not added", isPresented: Binding(get: { addProblem != nil }, set: { if !$0 { addProblem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(addProblem ?? "")
        }
        .confirmationDialog("Remove \(removing?.name ?? "this account")?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let account = removing else { return }
                Task { await model.removeAccount(account) }
            }
        } message: {
            Text(AccountWords.removeMessage(stopping: removing.map(model.agentsHolding(account:))?.count ?? 0,
                                            from: "this Mac"))
        }
    }

    /// A card of runtimes, each a short row (#3744): its name, one line and its allowance bar,
    /// then its accounts in the same way, then where it is in one line. **Details** opens the
    /// rest of the runtime's and its accounts' allowance: the times, the pace, the past weeks
    /// and the setup note.
    private func runtimeList(_ list: [RuntimeStatus]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, status in
                if index > 0 { Divider().padding(.leading, 14) }
                let rows = accountRows(for: status.id)
                let detailed = ([allowance(for: status.id)] + rows).contains { RuntimeStatusRow<EmptyView>.hasDetail($0, now: now) }
                let open = Binding(get: { expanded.contains(status.id) },
                                   set: { if $0 { expanded.insert(status.id) } else { expanded.remove(status.id) } })
                RuntimeStatusRow(status: status, allowance: allowance(for: status.id), at: now,
                                 showsDetail: open.wrappedValue) {
                    if case .needsSignIn = status.availability {
                        Button("Sign In…") { signingIn = status.id }
                            .controlSize(.small)
                    }
                    if status.runtime.accountFolderVariable != nil, !status.availability.isMissing {
                        Button("Add Account…") {
                            newName = ""
                            addingTo = status.runtime
                        }
                        .controlSize(.small)
                    }
                }
                // Each account added to it (#840), then the organisation's (#999), under
                // it, with its own allowance. Only one the person added can be signed in
                // or removed here; the organisation's is the organisation's.
                ForEach(rows) { row in
                    RuntimeStatusRow(status: status, allowance: row, at: now, title: row.title,
                                     showsDetail: open.wrappedValue) {
                        if let account = account(of: row) {
                            if !account.signedIn {
                                Button("Sign In…") { signingIn = status.id }
                                    .controlSize(.small)
                            }
                            Button("Remove…") { removing = account }
                                .controlSize(.small)
                        }
                    }
                    .padding(.leading, 14)
                }
                HStack(alignment: .firstTextBaseline) {
                    // With This Mac alone, the row's own line says it already.
                    if machines.count > 1 { MachinesLine(summary: summary(status.id), machines: machines) }
                    Spacer()
                    if detailed {
                        Button(open.wrappedValue ? "Hide Details" : "Details") { open.wrappedValue.toggle() }
                            .buttonStyle(.link)
                            .appText(.fine)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .paperRaised(in: RoundedRectangle(cornerRadius: 10))
    }

    private var now: Date { model.runtimeAllowances?.at ?? Date() }

    /// What a runtime's machines say of it, in their order.
    private func summary(_ runtimeID: String) -> RuntimeMachinesSummary<MachineRef> {
        RuntimeMachinesSummary(machines.map { host in
            (machine: host, status: model.runtimes(on: host).first { $0.id == runtimeID },
             online: !model.hosts.isOffline(host))
        })
    }

    /// The runtimes installed somewhere, or signed in (an allowance row of its own), first.
    /// With no machine yet, every runtime the Mac lists that is not missing.
    private var inUse: [RuntimeStatus] { runtimes.filter(isInUse) }
    private var others: [RuntimeStatus] { runtimes.filter { !isInUse($0) } }

    private func isInUse(_ status: RuntimeStatus) -> Bool {
        machines.isEmpty ? !status.availability.isMissing : summary(status.id).inUse
    }

    /// The account a row is for, when the person may sign it in or remove it: not an org account.
    private func account(of row: RuntimeAllowances.Row) -> AccountProfile? {
        row.accountID.flatMap { id in model.accountProfiles.first { $0.id == id && !$0.isOrganisation } }
    }

    /// This Mac, when it is one of the machines, then the others by name, as the sidebar's
    /// Machines lists them (#3626).
    private var machines: [MachineRef] {
        (model.hasMacHost ? [.mac] : []) + model.hosts.servers
    }

    /// Every runtime the app knows, in its own order. The daemon sends the whole list
    /// whether or not a runtime is on this Mac, so a missing one is here to be read
    /// rather than guessed at from the absence of a row.
    private var runtimes: [RuntimeStatus] { model.runtimes }

    /// The allowance row for a runtime, which is per credential: a runtime with a key of
    /// its own has more than one. The first is the runtime's own sign-in, which is the
    /// one a new agent would use.
    private func allowance(for runtimeID: String) -> RuntimeAllowances.Row? {
        model.runtimeAllowances?.row(runtimeID, account: nil)
    }

    private func accountRows(for runtimeID: String) -> [RuntimeAllowances.Row] {
        model.runtimeAllowances?.rows.filter { $0.runtimeID == runtimeID && $0.accountID != nil } ?? []
    }
}

/// A runtime's machines in one line (#3744): "On all 3 machines", or "On This Mac · Not on
/// build-box". Each machine's name is a link to its page (#3631), which has its whole line.
private struct MachinesLine: View {
    @Environment(AppModel.self) private var model
    let summary: RuntimeMachinesSummary<MachineRef>
    let machines: [MachineRef]

    var body: some View {
        // One Text, so a long line wraps; a name is a link that opens its machine's page.
        Text(attributed)
            .appText(.fine)
            .foregroundStyle(.secondary)
            .environment(\.openURL, OpenURLAction { url in
                guard let index = Int(url.host() ?? ""), machines.indices.contains(index) else { return .discarded }
                model.sidebarItem = .machine(machines[index])
                return .handled
            })
            .help("Each machine’s page has its runtimes, resources and disks")
            .accessibilityLabel(summary.words { model.hosts.label($0) })
    }

    private var attributed: AttributedString {
        var line = AttributedString()
        for (index, part) in summary.parts.enumerated() {
            if index > 0 { line += AttributedString(" · ") }
            line += AttributedString(part.words)
            for (n, host) in part.machines.enumerated() {
                line += AttributedString(n == 0 ? " " : ", ")
                var name = AttributedString(model.hosts.label(host))
                name.link = URL(string: "agents-machine://\(machines.firstIndex(of: host) ?? 0)")
                line += name
            }
        }
        return line
    }
}

/// One runtime, or one of its accounts, in a short row (#3744): its name, one line of what is
/// true of it and how much is left, its allowance bar, **Mark available** when it is out, and
/// the row's own buttons. With `showsDetail`, the reading's times, the pace, the past weeks and
/// the setup note too.
private struct RuntimeStatusRow<Actions: View>: View {
    @Environment(AppModel.self) private var model
    let status: RuntimeStatus
    let allowance: RuntimeAllowances.Row?
    let at: Date
    /// An added account's row is named for it too: "Claude · Work".
    var title: String?
    var showsDetail = false
    @ViewBuilder var actions: Actions

    /// Whether a row has anything for its Details.
    static func hasDetail(_ allowance: RuntimeAllowances.Row?, now: Date) -> Bool {
        guard let allowance else { return false }
        if allowance.setupNote != nil { return true }
        guard allowance.unusable == nil else { return false }
        return PoolWords.reading(allowance.state.reading, now: now) != nil
            || PoolWords.pace(allowance.state, now: now) != nil
            || PoolWords.pastWeeks(allowance.state, now: now) != nil
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title ?? status.runtime.name)
                    .fontWeight(.semibold)
                // An org account says where it is from (spec FR-023), never a key or an address.
                if allowance?.isOrganisation == true {
                    Text(OrgAccountWords.fromOrganisation)
                        .appText(.fine)
                        .foregroundStyle(.secondary)
                }
                Text(shortLine)
                    .appText(.fine)
                    .foregroundStyle(isOut ? StateTint.failure.style(or: .primary) : AnyShapeStyle(.secondary))
                if allowance?.unusable == nil, let current = allowance?.state.reading, reading != nil {
                    AllowanceBar(reading: current)
                        .help(reading ?? "")
                }
                if showsDetail { detail }
            }
            Spacer()
            if isOut, let allowance {
                Button("Mark available") {
                    Task { await model.markRuntimeAvailable(allowance.credentialKey) }
                }
                .controlSize(.small)
            }
            actions
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    /// What Details opens: the reading with its times, the pace, the past weeks, the setup note.
    @ViewBuilder private var detail: some View {
        if let reading, allowance?.unusable == nil {
            Text(reading)
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        if allowance?.unusable == nil, let pace = PoolWords.pace(allowance?.state, now: at) {
            Text(pace)
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
        if allowance?.unusable == nil, let past = AllowancePace(allowance?.state, now: at)?.past, !past.isEmpty,
           let words = PoolWords.pastWeeks(allowance?.state, now: at) {
            PastWeeksChart(past: past, words: words)
                .padding(.top, 2)
        }
        if let note = allowance?.setupNote {
            Text(LocalizedStringKey(note))
                .appText(.fine)
                .foregroundStyle(.secondary)
        }
    }

    /// The line, then how much is left while it is not out: "Available · 62% left this week".
    private var shortLine: String {
        guard !isOut, allowance?.unusable == nil, let amount = PoolWords.amount(allowance?.state.reading, now: at)
        else { return line }
        return "\(line) · \(amount)"
    }

    /// The allowance's own words where it has one, and the runtime's otherwise. What is
    /// not on this Mac is not an allowance state, so it is said in the runtime's terms.
    /// The install row keeps the size of a download and the buttons; this says what is.
    private var line: String {
        // A runtime the daemon found but nothing can start is that, whatever its plan
        // says. "Available" on a binary that is not here would be true of nothing.
        if let unusable = allowance?.unusable { return "Not usable: \(unusable)" }
        if let allowance { return allowance.memberLine(now: at) }
        switch status.availability {
        case .available: return "Available · no plan of its own"
        case .missing: return "Not on this Mac"
        case .needsSignIn, .failed: return status.unavailableReason ?? "Can’t be used"
        case .installing(let progress): return progress.map { "\($0)…" } ?? "Starting…"
        case .installFailed(let reason): return reason
        }
    }

    private var reading: String? {
        PoolWords.reading(allowance?.state.reading, now: at)
    }

    /// Out, and usable enough to say so. A runtime that cannot be started at all is a
    /// different thing, and marking it available would only hide that.
    private var isOut: Bool { allowance?.state.isOut == true && allowance?.unusable == nil }
}

/// The sidebar's way into Your setup (065, #3631). It says how many runtimes on this
/// Mac can start a turn, out of how many are installed (#379), and a red dot only when
/// none can: one being out does not matter, the work goes on on the others.
struct RuntimesRow: View {
    @Environment(AppModel.self) private var model

    private var tally: RuntimeTally? {
        RuntimeTally(model.runtimes, allowances: model.runtimeAllowances)
    }

    var body: some View {
        // The title alone (#587): how many work is the tooltip's, and none working turns
        // the row's icon red (`activityIcon(_:warns:)`).
        HStack(alignment: .firstTextBaseline) {
            Text("Runtimes").foregroundStyle(.primary)
            Spacer()
        }
        .help(tally.map { "\($0.working) of \($0.total) runtimes working. Your runtimes and accounts, and where each machine has them" }
              ?? "Your runtimes and accounts, and where each machine has them")
        .accessibilityValue(tally.map { $0.noneWorking ? "None of \($0.total) working" : "\($0.working) of \($0.total) working" } ?? "")
    }
}
