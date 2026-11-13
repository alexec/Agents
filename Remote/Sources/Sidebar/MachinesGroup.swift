import AgentsKitCore
import SwiftUI

/// New Machine, the Machines group's last row (#4034), as the window's header `+` (#3973): a
/// tap opens New Machine's sheet on the default provider (#4634); a long press offers New
/// Machine on ▸ when there are two or more providers (#3979). A row rather than a `+` in
/// the header, which iOS makes one button that folds the group. Adding a provider needs its
/// token, so that stays on the Mac and the web page: with none, there is no row.
struct NewMachineRow: View {
    @Environment(RemoteModel.self) private var model

    var body: some View {
        let providers = model.machineProviders
        Group {
            if let chosen = providers.first(where: { $0.default == true }) ?? providers.first {
                Button { model.newMachine() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus")
                            .sidebarMark(Paper.accent)
                            .frame(width: 20)
                            .accessibilityHidden(true)
                        Text("New Machine")
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .appText(.supporting)
                .accessibilityHint("Opens New Machine on \(chosen.name), with the options used last")
                .contextMenu {
                    Button("New Machine (\(chosen.name))…", systemImage: "plus") { model.newMachine() }
                    if providers.count > 1 {
                        Menu("New Machine on") {
                            ForEach(providers) { provider in
                                if provider.id == chosen.id {
                                    Button(provider.name, systemImage: "checkmark") { model.newMachine(on: provider.id) }
                                } else {
                                    Button(provider.name) { model.newMachine(on: provider.id) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A machine's row under Machines (#4034), as the window's (#3973) and the web page's (#3974):
/// the icon says its kind and its state (#4113), its name, and under it, in grey, the most
/// urgent thing it needs (#3764). Its sessions do not roll up into it. Swipes and the long
/// press start, stop, delete or remove it; a tap opens its page.
struct RemoteMachineRow: View {
    @Environment(RemoteModel.self) private var model
    let host: MachineRef
    @State private var deleting = false
    /// What Delete loses: the worktrees on it with work not pushed (#3979), asked as it opens.
    @State private var deleteWork: DaemonAPI.StartedMachinePreview?
    @State private var askingWork = false
    @State private var removing = false
    /// Stop, asked first while agents work there, with who they are.
    @State private var stoppingNames: [String] = []

    var body: some View {
        let name = model.machineName(host)
        let row = model.machineRow(host)
        let words = model.need(of: host).map { MachineNeedWords.line($0, name: name, row: row) }
        let actions = MachineRowActions.of(row, isThisMac: host == .mac)
        let dot = MachineDot.of(row, online: !model.machineOffline(host), starting: model.hostsBeingStarted.contains(host))
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MachineIconView(symbol: MachineIcon.symbol(isThisMac: host == .mac, row: row),
                            icon: MachineIcon.of(dot, diskLow: model.diskWarns(host), capacity: model.capacityLevel(host)))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                if let words {
                    Text(words)
                        .appText(.fine)
                        .foregroundStyle(Paper.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(words ?? (dot == .online ? "Online" : ""))
        .accessibilityHint("Opens \(name)’s page: its CPU, memory, disks and runtimes")
        .swipeActions(edge: .leading) {
            if actions.start {
                Button("Start", systemImage: "play") { Task { await model.startHost(host) } }.tint(Paper.accent)
            } else if actions.stop {
                Button("Stop", systemImage: "stop") { Task { await stop() } }.tint(Paper.accent)
            }
        }
        // A full swipe never deletes: Delete and Remove ask first.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if actions.delete {
                Button("Delete", systemImage: "trash") { askDelete() }.tint(StateTint.failure.color)
            } else if actions.remove {
                Button("Remove", systemImage: "minus.circle") { removing = true }.tint(.gray)
            }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.forward.app") { model.sidebarItem = .machine(host) }
            if actions.start {
                Button("Start", systemImage: "play") { Task { await model.startHost(host) } }
            } else if actions.stop {
                Button("Stop", systemImage: "stop") { Task { await stop() } }
            }
            if actions.delete {
                Divider()
                Button("Delete \(name)…", systemImage: "trash", role: .destructive) { askDelete() }
            } else if actions.remove {
                Divider()
                Button("Remove \(name)…", systemImage: "minus.circle") { removing = true }
            }
        }
        .confirmationDialog("Delete \(name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await model.deleteMachine(host) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let row {
                Text(MachineRowActions.deleteMessage(row, sessions: model.work.agents.filter { $0.host == host }.count,
                                                     preview: deleteWork, asking: askingWork))
            }
        }
        .confirmationDialog("Remove \(name)?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.removeMachine(host) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops connecting, and every window and device stops seeing it. Its agents are left running where they are.")
        }
        .confirmationDialog("Stop \(name)?", isPresented: Binding(get: { !stoppingNames.isEmpty },
                                                                  set: { if !$0 { stoppingNames = [] } }),
                            titleVisibility: .visible) {
            Button("Stop") { Task { _ = await model.stopHost(host, confirmed: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(ListFormatter.localizedString(byJoining: stoppingNames)) \(stoppingNames.count == 1 ? "is" : "are") working there. Stopping the machine stops them.")
        }
    }

    /// Stop asks only when sessions run there: the control plane says who.
    private func stop() async {
        if let names = await model.stopHost(host) { stoppingNames = names }
    }

    /// Delete asks at once, and the machine is asked meanwhile which worktrees have work not pushed.
    private func askDelete() {
        deleteWork = nil
        askingWork = true
        deleting = true
        Task {
            deleteWork = await model.deletePreview(host)
            askingWork = false
        }
    }
}

/// A machine New Machine made that has not joined yet (#4612), as the window's
/// `MakingMachineRow` and the web page's (#4610): an amber, pulsing cloud and *Making…* while
/// the control plane waits for it; red with the reason once it gave up, when the long press
/// and a swipe left offer Delete, asked first. Nil while providers/create has not answered:
/// a row at once, named once the provider names it. A machine of the person's that never
/// joined (#4978) is grey and *Not joined*: a tap or a swipe right joins it, the line says how
/// it goes, and Delete deletes it.
struct RemoteMakingMachineRow: View {
    @Environment(RemoteModel.self) private var model
    let making: MachineMaking?
    @State private var deleting = false

    var body: some View {
        let joined = making.flatMap { model.machineJoins[$0.id] }
        let name = making?.name ?? "New machine"
        let line = making?.line(joined) ?? "Making…"
        let failed = making?.failed(joined) ?? false
        let canDelete = making?.canDelete(joined) ?? false
        let hint = joined?.isJoining == true ? nil : making?.joinHint
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            MachineIconView(symbol: "cloud", icon: making?.icon(joined) ?? .busy)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).lineLimit(1)
                    .foregroundStyle(making?.joinable == true && joined == nil ? AnyShapeStyle(Paper.secondary) : AnyShapeStyle(.primary))
                Text(line)
                    .appText(.fine)
                    .foregroundStyle(failed ? StateTint.failure.style(or: .secondary) : AnyShapeStyle(Paper.secondary))
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .appText(.supporting)
        .contentShape(Rectangle())
        // A tap on one that never joined joins it (#4978).
        .onTapGesture { join(trust: nil) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(line)
        .accessibilityHint(hint ?? "")
        .accessibilityAddTraits(hint != nil ? .isButton : [])
        .accessibilityAction { join(trust: nil) }
        .accessibilityActions {
            if canDelete { Button("Delete") { deleting = true } }
        }
        // A swipe to the right joins it, as a tap does.
        .swipeActions(edge: .leading) {
            if hint != nil {
                Button(failed ? "Join Again" : "Join", systemImage: "arrow.right.circle") { join(trust: nil) }.tint(Paper.accent)
            }
        }
        // A full swipe never deletes: Delete asks first.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canDelete {
                Button("Delete", systemImage: "trash") { deleting = true }.tint(StateTint.failure.color)
            }
        }
        .contextMenu {
            if hint != nil {
                Button(failed ? "Join \(name) Again" : "Join \(name)", systemImage: "arrow.right.circle") { join(trust: nil) }
            }
            if canDelete {
                Button("Delete \(name)…", systemImage: "trash", role: .destructive) { deleting = true }
            }
        }
        .confirmationDialog("Trust \(name)’s host key?",
                            isPresented: Binding(get: { joined?.fingerprint != nil },
                                                 set: { if !$0, let making, joined?.fingerprint != nil { model.cancelJoin(making) } }),
                            titleVisibility: .visible) {
            Button("Trust and Join") { join(trust: joined?.fingerprint) }
            Button("Cancel", role: .cancel) { if let making { model.cancelJoin(making) } }
        } message: {
            Text("The control plane has not seen this key before: \(joined?.fingerprint ?? ""). Join only if it is \(name)’s.")
        }
        .confirmationDialog("Delete \(name)?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let making { Task { await model.deleteWorkspace(making.provider, workspace: making.workspace) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(making?.deleteMessage ?? "")
        }
    }

    private func join(trust: String?) {
        guard let making, making.canJoin else { return }
        Task { await model.joinMachine(making, trust: trust) }
    }
}
