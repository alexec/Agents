import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Machines (#4034), as the window's Machines group (#3973)

    /// The Machines group's rows: This Mac first, then every other machine the control plane
    /// lists. None against a bridge with no control plane.
    var machines: [MachineRef] {
        guard let home = controlHome, !controlHosts.isEmpty else { return [] }
        return [.mac] + controlHosts.map(\.id).filter { $0 != home && $0 != .mac }
    }

    /// A machine's row as `machines/list` last said it; This Mac's is the home host's.
    func machineRow(_ host: MachineRef) -> DaemonAPI.ControlMachine? {
        host == .mac ? controlHosts.first { $0.id == controlHome } : controlHost(host)
    }

    /// A machine's name in the group: This Mac, or the name the control plane gave it.
    func machineName(_ host: MachineRef) -> String {
        guard host != .mac, let row = controlHost(host) else { return host == .mac ? "This Mac" : host.rawValue }
        return row.name.isEmpty ? host.rawValue : row.name
    }

    /// Whether the machine answers calls now, as its row last said.
    func machineOffline(_ host: MachineRef) -> Bool {
        machineRow(host).map { !$0.answers } ?? false
    }

    func receivedDisk(_ state: DiskState?, from host: MachineRef) {
        serverDisks[host] = state
    }

    /// What the machine says of its disks now, as it joins (#3628).
    func refreshServerDisk(_ host: MachineRef) async {
        guard let other = otherHosts[host],
              let state = try? await other.call(DaemonAPI.Method.diskState, Optional<String>.none, returning: DiskState.self)
        else { return }
        serverDisks[host] = state
        if let capacity = try? await other.call(DaemonAPI.Method.capacityState, Optional<String>.none,
                                                returning: DaemonAPI.CapacityState.self) {
            work.replaceCapacity(capacity, from: host)
        }
    }

    /// A machine's most urgent need, as its row says it (#3764).
    func need(of host: MachineRef) -> MachineNeed? {
        MachineNeed.most(row: machineRow(host), offline: machineOffline(host),
                         runtimes: runtimes(on: host), disks: diskAlarms(host), capacity: capacityLevel(host))
    }

    /// The machine's capacity level, as it last pushed it (#4748); nil while it is offline,
    /// where what it last said is old.
    func capacityLevel(_ host: MachineRef) -> DaemonAPI.CapacityLevel? {
        machineOffline(host) ? nil : work.capacity[host]?.level
    }

    /// Whether a disk on the machine is low or almost full, as its page says (#3626).
    /// Not while it is offline: what its disks last said is old, and its line says why it is quiet.
    func diskWarns(_ host: MachineRef) -> Bool {
        !machineOffline(host) && diskAlarms(host).contains { $0.level != .ok }
    }

    func diskAlarms(_ host: MachineRef) -> [DiskAlarm] {
        host == .mac ? work.disk.alarms : serverDisks[host]?.alarms ?? []
    }

    /// The providers New Machine can use (#3979), for the Machines header's menu.
    var machineProviders: [DaemonAPI.ProviderSummary] { listedProviders.filter { $0.capabilities.contains("create") } }

    /// The machines New Machine made that have not joined (#4612): *Making…* while the control
    /// plane waits for them, red with its reason once it gave up. A row each under Machines; and
    /// every other machine of the person's that has not joined, grey, a tap to join it (#4978).
    var machinesMaking: [MachineMaking] {
        MachineMaking.rows(listedProviders, hostNames: Set(controlHosts.map(\.name)))
    }

    /// Delete on a machine the control plane gave up waiting for (#4612): the provider deletes
    /// the workspace. Nothing was installed on it.
    func deleteWorkspace(_ provider: ProviderID, workspace: String) async {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering, so the machine wasn’t deleted."
            return
        }
        do {
            _ = try await control.call(DaemonAPI.Method.providersDeleteWorkspace,
                                       DaemonAPI.ProviderWorkspaceRequest(id: provider, workspace: workspace))
        } catch {
            problem = sentence(for: error)
        }
        await loadMachineProviders()
    }

    /// Stop on a machine's row (#3973). Unconfirmed while agents work there, the control plane
    /// says who they are, and they are returned for the question; nil once it is stopping or refused.
    func stopHost(_ host: MachineRef, confirmed: Bool = false) async -> [String]? {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering, so \(machineName(host)) could not be stopped."
            return nil
        }
        do {
            _ = try await control.call(DaemonAPI.Method.hostsStop,
                                       DaemonAPI.MachineStop(host: host, confirmRunning: confirmed ? true : nil))
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.agentsWorking {
            let names = error.data?["running"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !names.isEmpty { return names }
            problem = sentence(for: error)
        } catch {
            problem = sentence(for: error)
        }
        return nil
    }

    /// Delete… on a machine a provider made (#3973): the provider deletes it, then the host goes.
    func deleteMachine(_ host: MachineRef) async {
        await machineCall(DaemonAPI.Method.hostsDeleteMachine, host)
    }

    /// Remove… on a registered machine (#3973): Agents forgets it; the computer stays.
    func removeMachine(_ host: MachineRef) async {
        await machineCall(DaemonAPI.Method.hostsRemove, host)
    }

    func machineCall(_ method: String, _ host: MachineRef) async {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering."
            return
        }
        do {
            _ = try await control.call(method, DaemonAPI.MachineRequest(host: host))
            controlHosts.removeAll { $0.id == host }
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Delete's question (#3979): the worktrees on the machine with work not pushed. Nil when
    /// the control plane can't say.
    func deletePreview(_ host: MachineRef) async -> DaemonAPI.StartedMachinePreview? {
        try? await controlPlane?.call(DaemonAPI.Method.hostsDeletePreview, DaemonAPI.MachineRequest(host: host),
                                      returning: DaemonAPI.StartedMachinePreview.self)
    }

    /// New Machine (#3973, #4634): the sheet, on the default provider or the one New Machine
    /// on ▸ names, with every field on what New Machine would make. Make confirms it.
    func newMachine(on provider: ProviderID? = nil) {
        newMachineAsk = NewMachineAsk(provider: provider)
    }

    /// The New Machine sheet's form (#4634): the provider's schema and the values to start with.
    func newMachineForm(_ provider: ProviderID?) async -> Result<DaemonAPI.ProviderOptions, NewMachineRefusal> {
        guard let control = controlPlane else {
            return .failure(.init("The control plane isn’t answering, so no machine can be made."))
        }
        do {
            return .success(try await control.call(DaemonAPI.Method.providersOptions, DaemonAPI.ProviderRequest(id: provider),
                                                   returning: DaemonAPI.ProviderOptions.self))
        } catch {
            return .failure(.init(sentence(for: error)))
        }
    }

    /// Make on the New Machine sheet (#4634): the sheet closes at once and a *Making…* row
    /// takes over (#4612). A make the provider refuses opens the sheet again on the same
    /// choices, with the provider's reason.
    func makeMachine(_ draft: NewMachineDraft) {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering, so no machine can be made."
            return
        }
        machinesBeingMade += 1
        Task {
            defer { machinesBeingMade -= 1 }
            var refused: String?
            do {
                let made = try await control.call(
                    DaemonAPI.Method.providersCreate,
                    DaemonAPI.ProviderCreate(id: draft.provider, name: draft.name, options: .object(draft.values)),
                    returning: DaemonAPI.ProviderCreated.self)
                if made.workspace.state == "failed" {
                    refused = made.workspace.reason ?? "\(made.workspace.name) could not be made."
                }
            } catch {
                refused = sentence(for: error)
            }
            if let refused { newMachineAsk = NewMachineAsk(provider: draft.provider, again: draft, problem: refused) }
            await loadMachineProviders()
        }
    }

    func heardProviders(_ params: JSONValue?) {
        guard let listed = try? params?["providers"]?.decode([DaemonAPI.ProviderSummary].self) else { return }
        listedProviders = listed.filter(\.usable)
    }

    /// A tap on a machine that never joined (#4978), as the window's joinMachine: the control
    /// plane installs Agents on it over ssh; the row says each step, and why it failed.
    func joinMachine(_ row: MachineMaking, trust: String? = nil) async {
        guard row.canJoin, machineJoins[row.id]?.isJoining != true, let ssh = row.ssh else { return }
        guard let control = controlPlane else {
            machineJoins[row.id] = .failed("The control plane isn’t answering.")
            return
        }
        machineJoins[row.id] = .joining(step: nil)
        var params: [String: JSONValue] = ["destination": .string(ssh), "name": .string(row.name),
                                           "tunnel": .bool(row.tunnel), "provider": .string(row.provider.rawValue),
                                           "workspace": .string(row.workspace)]
        if let trust { params["trust"] = .string(trust) }
        do {
            let answer = try await control.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
            if let fingerprint = answer["needsTrust"]?.stringValue {
                machineJoins[row.id] = .needsTrust(fingerprint)
            } else {
                machineJoins[row.id] = .joining(step: "started")
            }
        } catch {
            machineJoins[row.id] = .failed(sentence(for: error))
        }
        await loadMachineProviders()
    }

    /// Forgets a join's host key question: the person did not trust it.
    func cancelJoin(_ row: MachineMaking) { machineJoins[row.id] = nil }

    /// `control/installProgress`: the step of a join, on the row of its name.
    func heardInstallStep(_ params: JSONValue?) {
        guard let name = params?["name"]?.stringValue, let step = params?["step"]?.stringValue,
              let row = machinesMaking.first(where: { $0.name == name }), machineJoins[row.id]?.isJoining == true
        else { return }
        machineJoins[row.id] = .joining(step: step)
    }

    func loadMachineProviders() async {
        guard let control = controlPlane,
              let answer = try? await control.call(DaemonAPI.Method.providersList, DaemonAPI.Empty()),
              let listed = try? answer["providers"]?.decode([DaemonAPI.ProviderSummary].self)
        else { return }
        listedProviders = listed.filter(\.usable)
    }

    /// A machine's runtimes, asked again as its page opens (#3629).
    func refreshMachineRuntimes(_ host: MachineRef) async {
        if host == .mac { await refreshRuntimes() } else { await refreshServerRuntimes(host) }
    }

    /// Sign In… on a server's Claude or Codex (#4035), as the web page's (#3349): the machine
    /// runs the runtime's own sign-in and gives the link to open here.
    func runtimeSignInStart(_ runtimeID: String, on host: MachineRef) async throws -> DaemonAPI.RuntimeSignInStep {
        try await client(for: DaemonAPI.Empty(), on: host)
            .call(DaemonAPI.Method.runtimesSignInStart, DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                  returning: DaemonAPI.RuntimeSignInStep.self)
    }

    /// The end of that sign-in: the code Claude's page gave, nothing for Codex, or cancel.
    func runtimeSignInFinish(_ finish: DaemonAPI.RuntimeSignInFinish, on host: MachineRef) async throws {
        _ = try await client(for: DaemonAPI.Empty(), on: host)
            .call(DaemonAPI.Method.runtimesSignInFinish, finish, returning: RuntimeStatus.self)
        await refreshMachineRuntimes(host)
    }

    /// An API key for the runtime, kept on the machine.
    func runtimeSignInKey(_ runtimeID: String, key: String, on host: MachineRef) async throws {
        _ = try await client(for: DaemonAPI.Empty(), on: host)
            .call(DaemonAPI.Method.runtimesSignInKey, DaemonAPI.RuntimeSignInKey(runtimeID: runtimeID, key: key),
                  returning: RuntimeStatus.self)
        await refreshMachineRuntimes(host)
    }

    /// Update on a machine's runtime (#4035): the machine installs the app's newer copy over
    /// the one it has. It says how that goes in runtime/changed.
    func updateRuntime(_ runtimeID: String, on host: MachineRef) async {
        do {
            _ = try await client(for: DaemonAPI.Empty(), on: host)
                .call(DaemonAPI.Method.runtimesInstall, DaemonAPI.RuntimeRequest(runtimeID: runtimeID),
                      returning: RuntimeStatus.self)
        } catch {
            problem = sentence(for: error)
        }
        await refreshMachineRuntimes(host)
    }

    /// A machine's CPU, memory and disks for its page (#3626), asked of the machine itself.
    func machineUsage(_ host: MachineRef) async throws -> DaemonAPI.MachineUsageState {
        try await client(for: DaemonAPI.Empty(), on: host)
            .call(DaemonAPI.Method.machineUsage, DaemonAPI.Empty(), returning: DaemonAPI.MachineUsageState.self)
    }

    /// A host's git asking to use a Mac's git access (#1122), not answered here yet. Any
    /// client may answer it; the control plane takes the first answer.
    var gitLendAsk: GitLendAsk? {
        GitLendAsk.first(in: controlHosts, thisMac: nil, answered: gitAsksAnswered)
    }

    /// Approve or Deny on the ask.
    func answerGitLend(_ ask: GitLendAsk, allowed: Bool) async {
        gitAsksAnswered.insert(ask.id)
        await lendGit(host: ask.host, from: ask.from, server: ask.server, allowed: allowed)
    }

    /// Said to the control plane; Settings ▸ Git access takes one back with `allowed` false.
    func lendGit(host: MachineRef, from: MachineRef, server: String, allowed: Bool) async {
        guard let control = controlPlane else {
            problem = "The control plane isn’t answering, so that was not changed."
            return
        }
        do {
            _ = try await control.call(DaemonAPI.Method.hostsLendGit,
                                       DaemonAPI.LendGit(host: host, from: from, server: server, allowed: allowed))
            if !allowed, let index = controlHosts.firstIndex(where: { $0.id == host }) {
                controlHosts[index].gitFrom?[server] = nil
            }
        } catch {
            problem = sentence(for: error)
        }
    }

    /// Ask whether a control plane is on the other end, and follow its other hosts if so.
    /// A bridge with no control plane answers `control/status` with methodNotFound, and
    /// nothing more happens.
    ///
    /// Holds the model only for each step, never for the whole watch: a model let go (a
    /// new pairing) ends its watch rather than being kept dialling by it (#175). `stop`
    /// ends it at once.
    func watchOtherHosts() {
        guard hostWatch == nil, !reconnect.isStopped else { return }
        let client = client
        let base: any DaemonLink = baseLink
        let backoff = otherHostsBackoff
        hostWatch = Task { [weak self] in
            guard (try? await client.call(DaemonAPI.Method.controlStatus)) != nil else {
                self?.hostWatch = nil
                return
            }
            let link = ControlLink { try await base.transport() }
            let control = DaemonClient(link: link.controlLink)
            defer { Task { await control.disconnect() } }
            while !Task.isCancelled, self != nil {
                backoff.trying()
                if (try? await control.connect(startIfNeeded: false, timeout: .seconds(5))) != nil {
                    backoff.connected()
                    self?.controlPlane = control
                    await self?.syncOtherHosts(control, link: link)
                    await self?.loadMachineProviders()
                    await self?.loadKept(control)
                    await self?.people.connected(control)
                    await self?.signIn.connected(control)
                    // Status ▸ Secrets and Accounts' rows say when the newest operation was (#4161).
                    await self?.userScope.load(control)
                    if let client = RemoteControl.membership?.client { await self?.lock.connected(control, client: client) }
                    await Self.sealWaiting(on: control, lock: self?.lock)
                    for await change in control.notifications() {
                        guard let self, !Task.isCancelled else { return }
                        if change.method == DaemonAPI.Notification.controlSealingWanted {
                            await Self.sealWaiting(on: control, lock: self.lock)
                            continue
                        }
                        if await self.people.heard(change.method, change.params, on: control) { continue }
                        if self.signIn.heard(change.method, change.params) { continue }
                        if await self.userScope.heard(change.method, change.params, on: control) { continue }
                        if await self.lock.heard(change.method, change.params, on: control) {
                            // A machine just added to the lock may now be sealed to (#3491, D8).
                            if change.method == DaemonAPI.Notification.controlLockChanged { await Self.sealWaiting(on: control, lock: self.lock) }
                            continue
                        }
                        if change.method == DaemonAPI.Notification.controlKeptChanged
                            || change.method == DaemonAPI.Notification.controlKeptDelivered {
                            await self.heardKept(change.method, change.params)
                            continue
                        }
                        if change.method == DaemonAPI.Notification.controlProvidersChanged {
                            // The Machines group's New Machine row and its default (#4034).
                            self.heardProviders(change.params)
                            continue
                        }
                        if change.method == DaemonAPI.Notification.controlInstallProgress {
                            // A join from the Machines group says its step on its row (#4978).
                            self.heardInstallStep(change.params)
                            continue
                        }
                        guard change.method == DaemonAPI.Notification.controlHostChanged else { continue }
                        // A host back while this phone waits out its backoff: go back now (#172).
                        if !self.isConnected, DaemonAPI.ControlMachine.answers(change.params?["state"]?.stringValue) { self.backoff.nudge() }
                        await self.syncOtherHosts(control, link: link)
                    }
                    note("hosts: the control plane's watch closed")
                    if self?.controlPlane === control {
                        self?.controlPlane = nil
                        self?.people.went()
                        self?.signIn.went()
                        self?.lock.went()
                    }
                }
                guard !Task.isCancelled, self != nil else { return }
                await backoff.wait()
            }
        }
    }

    /// Seals what waits for a copy this device can make (#3397): a machine that joined, or a
    /// client paired, after an org route or one of the person's secrets was sealed.
    static func sealWaiting(on control: DaemonClient, lock: LockState?) async {
        // Only to the machines the lock names (#3491, D8).
        guard let lock else { return }
        guard let (key, client) = RemoteControl.sealing() else { return }
        await ClientSealing.sealWaiting(on: control, key: key, client: client) { await lock.signed($0, on: control) }
    }

    /// Everything this model dials, ended for good: a new pairing has made a new model
    /// (#175). Stopped first, so nothing below starts a loop again: the listener's end,
    /// a network change, a send (#208).
    func stop() async {
        note("link: stopping this pairing's connections")
        reconnect.stop()
        networkChanges.stop()
        hostWatch?.cancel()
        hostWatch = nil
        controlPlane = nil
        people.went()
        signIn.went()
        lock.went()
        listening?.cancel()
        listening = nil
        for (_, other) in otherHosts { await other.disconnect() }
        otherHosts = [:]
        reachableHosts = []
        await client.disconnect()
    }

    func syncOtherHosts(_ control: DaemonClient, link: ControlLink) async {
        guard let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self),
              let listed = try? await control.call(DaemonAPI.Method.hostsList, returning: [DaemonAPI.ControlMachine].self)
        else { return }
        controlHosts = listed
        gitAsksAnswered.formIntersection(GitLendAsk.waiting(in: listed))
        controlHome = status.homeHost
        controlStatus = status
        let onHomeMac = ControlPlaneReach.onHomeMac(status, hosts: listed)
        WindowDefaults.store.set(onHomeMac, forKey: Self.planeOnMacKey)
        controlPlaneReach = ControlPlaneReach(onHomeMac: onHomeMac, address: ControlPlaneReach.address(of: RemoteControl.membership?.url))
        OlderPeer.controlVersion = status.version
        OlderPeer.know(listed, home: status.homeHost)
        let others = listed.filter { $0.id != status.homeHost && $0.answers }
        for host in others {
            let lock = lock
            let other = otherHosts[host.id] ?? DaemonClient(link: LockedLink(link.link(for: host.id), host: host.id) { await lock.channelSigner() },
                                                         machine: host.id)
            otherHosts[host.id] = other
            if await other.isConnected { continue }
            reachableHosts.remove(host.id)
            guard (try? await other.connect(startIfNeeded: false, timeout: .seconds(5))) != nil else { continue }
            let id = host.id
            reachableHosts.insert(id)
            // A start there with no key of its own asks this device for one (#344).
            await other.setCredentialLender { [weak self] wanted in
                await self?.answerCredentialWanted(wanted, on: id) ?? false
            }
            if let folders = try? await other.call(DaemonAPI.Method.foldersList,
                                                    DaemonAPI.FoldersListRequest(includeArchived: false),
                                                    returning: [DaemonAPI.FolderSummary].self) {
                work.replaceFolders(folders, from: id)
                pruneFolderDefaults(of: id, listed: folders)
                startHostMoved()
                lookForShared()
            }
            // Its folders' MCP servers, for their rows in the sidebar (#753).
            if let health = try? await other.call(DaemonAPI.Method.mcpHealth, Optional<String>.none,
                                                  returning: DaemonAPI.MCPHealthSnapshot.self) {
                work.replaceMCPHealth(health, from: id)
            }
            if let agents = try? await other.listAgents(DaemonAPI.ListRequest(includeArchived: false, lean: true)) {
                work.replaceAgents(agents, from: id)
            }
            await refreshServerRuntimes(id)
            await refreshServerDisk(id)
            await refreshMoves(on: id, through: other)
            await machineBrowsers[id]?.rewatchIfWatching()
            let notes = other.notifications()
            let shown = work.shown
            // Read off the main actor, once, and applied there (#203).
            Task.detached(priority: .userInitiated) { [weak self] in
                for await note in notes {
                    // Its browser, for the agent browser's take-over window alone (#4141) (#3800).
                    if Self.browserNotifications.contains(note.method) {
                        await self?.receivedBrowser(note.method, note.params, from: id)
                        continue
                    }
                    // Its runtimes, and the start page's draft made there (#240).
                    if note.method == DaemonAPI.Notification.runtimeChanged
                        || note.method == DaemonAPI.Notification.costChanged
                        || note.method == DaemonAPI.Notification.draftOptions {
                        await self?.received(note.method, note.params, fromOther: id)
                        continue
                    }
                    // A move from that machine to another (#4641), for the session's card.
                    if note.method == DaemonAPI.Notification.moveChanged {
                        if let change = try? note.params?.decode(DaemonAPI.MoveNotification.self) {
                            await self?.moveChanged(change)
                        }
                        continue
                    }
                    // A machine's disks, for its row and its page (#4034).
                    if note.method == DaemonAPI.Notification.diskChanged {
                        await self?.receivedDisk(try? note.params?.decode(DiskState.self), from: id)
                        continue
                    }
                    // Settings ▸ Backups is the Mac's (#1810).
                    if note.method == DaemonAPI.Notification.resourcesChanged
                        || note.method == DaemonAPI.Notification.mcpHostedChanged
                        || note.method == DaemonAPI.Notification.eventsChanged
                        || note.method == DaemonAPI.Notification.backupsChanged { continue }
                    // The Multiplier and the achievements are the Mac's host's, which counts
                    // every machine (#3903, #4116): another's would put its own over them.
                    if note.method == DaemonAPI.Notification.multiplierChanged
                        || note.method == DaemonAPI.Notification.achievementsChanged { continue }
                    guard let update = AgentsModel.read(note.method, note.params, showing: shown.id,
                                                         alsoShowing: shown.also) else { continue }
                    let added = await self?.work.addsFolder(update, from: id) ?? false
                    await self?.work.apply(update, from: id)
                    await self?.applyToPopouts(update)
                    if added { await self?.refreshWorkflows() }
                }
                // Its connection ended: its cards are stale until the watch reaches it again.
                await MainActor.run { [weak self] in
                    if self?.otherHosts[id] === other { self?.reachableHosts.remove(id) }
                }
            }
            // A new connection is a new record there: where the person is, and what is open.
            presence?.connected()
        }
        // One offline or stopped when this started lists what it last did, greyed, as one that
        // went while it ran (#962).
        for host in controlHosts where host.id != status.homeHost && !host.answers
            && !work.holdsFolders(of: host.id) {
            if let heard = try? await control.call(DaemonAPI.Method.hostsLastHeard, DaemonAPI.MachineRequest(host: host.id),
                                                   returning: DaemonAPI.MachineLastHeard.self) {
                work.takeLastHeard(heard)
            }
        }
        // A host that went offline keeps its folders, greyed under its heading (frame H).
        // One the control plane no longer lists is gone, and so is what it showed.
        for id in otherHosts.keys where !others.contains(where: { $0.id == id }) {
            reachableHosts.remove(id)
            await otherHosts.removeValue(forKey: id)?.disconnect()
            if !listed.contains(where: { $0.id == id }) {
                work.replaceFolders([], from: id)
                work.replaceAgents([], from: id)
                serverRuntimes[id] = nil
                pruneFolderDefaults(of: id, listed: [])
            }
        }
    }

    /// What another host says that the shared model does not claim, and the phone wants:
    /// its runtimes changing, and the start page's draft settling there (#240).
    func received(_ method: String, _ params: JSONValue?, fromOther host: MachineRef) async {
        switch method {
        case DaemonAPI.Notification.runtimeChanged:
            await refreshServerRuntimes(host)
        case DaemonAPI.Notification.draftOptions:
            guard host == startDraftHost,
                  let change = try? params?.decode(DaemonAPI.DraftOptionsNotification.self) else { return }
            settleStartDraft(change)
        default:
            break
        }
    }

    func listen() {
        listening?.cancel()
        let notifications = client.notifications()
        let shown = work.shown
        // Detached, so that each notification is decoded once, off the main actor, and
        // only what it means is applied there, in the order the Mac said them (#203).
        // An entry or terminal output for another chat is not read past its agentID.
        listening = Task.detached(priority: .userInitiated) { [weak self] in
            for await notification in notifications {
                let update = AgentsModel.read(notification.method, notification.params, showing: shown.id,
                                              alsoShowing: shown.also)
                guard let self else { return }
                await self.received(notification, update)
            }
            // Cancelled is not lost: a newer listener took over, or the model was stopped,
            // and either way this one's end is not a reason to go back (#208).
            guard !Task.isCancelled else { return }
            await self?.lostTouch()
        }
    }

    func received(_ notification: (method: String, params: JSONValue?), _ update: AgentsModel.Update?) {
        self.lastHeardFrom = Date()
        if Self.browserNotifications.contains(notification.method) {
            receivedBrowser(notification.method, notification.params, from: .mac)
            return
        }
        var updated: Agent?
        if case .agentChanged(let agent)? = update { updated = agent }
        let previousLabels = updated.flatMap { self.work.agent($0.id)?.labels }
        var removedFolder: URL?
        if case .agentRemoved(let removed)? = update { removedFolder = self.work.agent(removed.agentID)?.folderPath }
        // Anything the shared model does not claim is the Mac's own — shells,
        // terminals — and a remote has no business with it.
        if let update {
            // A folder added has workflows no notification brings (#1798).
            let added = self.work.addsFolder(update)
            self.work.apply(update)
            applyToPopouts(update)
            if added { Task { await refreshWorkflows() } }
        }
        // Nothing below waits on the network: one slow answer would hold every
        // notification after it (#175). What needs asking is asked beside the loop.
        if let updated, previousLabels != updated.labels,
           self.labelVocabularies[updated.folderPath] != nil {
            self.reloadLabelVocabulary(in: updated.folderPath)
        }
        if let removedFolder, self.labelVocabularies[removedFolder] != nil {
            self.reloadLabelVocabulary(in: removedFolder)
        }
        if notification.method == DaemonAPI.Notification.moveChanged,
           let change = try? notification.params?.decode(DaemonAPI.MoveNotification.self) {
            moveChanged(change)
        }
        if notification.method == DaemonAPI.Notification.dailySummaryChanged,
           let settings = try? notification.params?.decode(DailySummarySettings.self) {
            self.dailySummarySettings = settings
        }
        if notification.method == DaemonAPI.Notification.summariesChanged,
           let pages = try? notification.params?.decode([SummaryPage].self) {
            self.summaryPages = pages
        }
        if notification.method == DaemonAPI.Notification.preferencesChanged,
           let preferences = try? notification.params?.decode(DaemonAPI.DisplayPreferences.self) {
            self.displayMirror.hostSaid(preferences)
        }
        if Self.attentionNotifications.contains(notification.method) {
            self.publishAttentionSoon()
        }
        // The Live Activity of a turn sent from here (#1657): what the session does, and asks.
        if case .agentChanged(let agent)? = update {
            liveActivities.changed(agent.id, in: work)
        } else if case .agentRemoved(let removed)? = update {
            liveActivities.changed(removed.agentID, in: work)
        } else if case .attention(let change)? = update, let agentID = change.need?.agentID {
            liveActivities.changed(agentID, in: work)
        }
        if case .attention(let change)? = update {
            self.toNotifier { [deviceID = self.deviceID] notifier in
                await notifier.apply(change, me: .device(deviceID))
            }
        }
        if notification.method == DaemonAPI.Notification.draftOptions,
           let change = try? notification.params?.decode(DaemonAPI.DraftOptionsNotification.self) {
            self.settleStartDraft(change)
        }
        // The Mac sends a device only the shells it has open (034).
        if notification.method == DaemonAPI.Notification.shellOutput,
           let params = notification.params,
           let output = DaemonAPI.ShellOutputNotification(params: params) {
            self.shells[ShellKey(agentID: output.agentID, shell: output.shell)]?.received(output.bytes, at: output.offset)
        }
        if notification.method == DaemonAPI.Notification.shellStateChanged,
           let change = try? notification.params?.decode(DaemonAPI.ShellStateNotification.self) {
            self.shells[ShellKey(agentID: change.agentID, shell: change.shell)]?.received(change.state)
        }
        if notification.method == DaemonAPI.Notification.filesChanged,
           let change = try? notification.params?.decode(DaemonAPI.FilesChangedNotification.self) {
            self.files.apply(change)
        }
        if notification.method == DaemonAPI.Notification.runtimesAccountProfilesChanged,
           let list = try? notification.params?.decode([AccountProfile].self) {
            self.accountProfiles = list
        }
        if notification.method == DaemonAPI.Notification.sandboxChanged,
           let settings = try? notification.params?.decode(SandboxSettings.self) {
            self.sandboxSettings = settings
        }
        if notification.method == DaemonAPI.Notification.autoChanged {
            Task { await refreshAuto(); await refreshStartAutoPreview() }
        }
        if notification.method == DaemonAPI.Notification.clientPermissionsChanged,
           let settings = try? notification.params?.decode(ClientPermissionSettings.self) {
            self.clientPermissions = settings
        }
        if notification.method == DaemonAPI.Notification.daemonPolicyStateChanged,
           let state = try? notification.params?.decode(DaemonAPI.PolicyState.self) {
            self.policyState = state
            // The marks on the lists change with the policy: read them again (#998).
            Task {
                await self.refreshRuntimes()
                await self.refreshSandboxSettings()
                await self.refreshCostState()
            }
        }
        if notification.method == DaemonAPI.Notification.policyEffectiveChanged {
            self.policyRevision += 1
        }
        if notification.method == DaemonAPI.Notification.runtimeChanged, self.parts.changed(.runtimes) {
            self.reloadRuntimes()
        }
        // The Mac could not keep something nobody was waiting on (#88).
        if notification.method == DaemonAPI.Notification.writeFailed,
           let failure = try? notification.params?.decode(WriteFailure.self) {
            self.problem = failure.message
        }
        if notification.method == DaemonAPI.Notification.runtimeAccountChanged,
           let account = try? notification.params?.decode(RuntimeAccount.self) {
            self.accounts[account.runtimeID] = account
        }
        if notification.method == DaemonAPI.Notification.deviceChanged,
           let change = try? notification.params?.decode(DaemonAPI.DeviceNotification.self),
           change.id == self.deviceID {
            self.thisDevice = change.device
            self.subscribeOnce()
        }
    }

    /// The Mac stopped answering. Say so, keep what is on screen, and go back for it.
    func lostTouch() async {
        guard !reconnect.isStopped else { return }
        note("link: lost touch")
        isConnected = false
        parts.connectionLost()
        listening = nil
        await connect()
    }
}
