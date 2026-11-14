import AgentsKitCore
import AppKit
import Foundation
import os

/// Servers (037): machines joining, their hosts and files.
extension AppModel {
    // MARK: Servers (037)

    /// A server's pictures for its live pages, kept while the app runs (037).
    func serverPictures(_ host: MachineRef) -> ServerPictures {
        if let known = serverPicturesByHost[host] { return known }
        let made = ServerPictures(files: serverFiles(host))
        serverPicturesByHost[host] = made
        return made
    }

    /// How the files pane reads a server agent's folder: through that server's daemon,
    /// because the folder is not on this Mac.
    func serverFiles(_ host: MachineRef) -> RemoteFiles {
        if let known = serverFilesByHost[host] { return known }
        let made = RemoteFiles(client: client(for: host))
        serverFilesByHost[host] = made
        return made
    }

    /// Once, after the Mac's own daemon has answered: the servers come after the Mac,
    /// so a slow server never holds up the window's first list.
    func startHosts() {
        guard !hostsStarted else { return }
        hostsStarted = true
        let shown = work.shown
        hosts.onNotification = { [weak self] host, method, params in
            // Read off the main actor, as the Mac's own are (#203).
            let update = await Task.detached { AgentsModel.read(method, params, showing: shown.id, alsoShowing: shown.also) }.value
            await self?.receivedFromServer(host, method, params, update)
        }
        hosts.offerFor = { [weak self] id in self?.credentialOffer(id) }
        hosts.lenderFor = { [weak self] id in
            { [weak self] wanted in
                guard let model = self else { return false }
                return await model.answerCredentialWanted(wanted, on: id)
            }
        }
        hosts.toolsetWanted = { [weak self] id, runtimeID in
            guard let self else { return false }
            // One that works with no sign-in goes wherever this Mac has it (049: OpenCode's free
            // models); on an "own sign-in only" server too, since nothing is lent to install it.
            if RuntimeLaunchCatalog.launch(for: runtimeID).lentSignIn != nil { return self.hasOnThisMac(runtimeID) }
            // No runtime takes a pasted key from Settings now that Gemini is retired (#3043).
            return false
        }
        hosts.onConnected = { [weak self] host in
            await self?.refreshServer(host)
            await self?.reattachShells(on: host)
        }
        hosts.onReachability = { [weak self] server, online in
            guard let self else { return }
            _ = try? await self.client.call(DaemonAPI.Method.eventsServer,
                                            DaemonAPI.ServerReachabilityChange(server: server, online: online),
                                            returning: Event.self)
        }
        hosts.start()
    }

    /// Follow the control plane's hosts: a client for each one other than this Mac's,
    /// listed now and kept as hosts come and go (058, US3).
    func watchControlHosts() {
        guard let controlLink, controlWatch == nil else { return }
        let backoff = controlBackoff
        controlWatch = Task { [weak self] in
            let control = DaemonClient(link: controlLink.controlLink)
            self?.controlRequests = control
            while !Task.isCancelled {
                // Before the list comes, and while the control plane stays away (#1481).
                await self?.reachKeptHost(controlLink)
                backoff.trying()
                let answered: Bool
                do {
                    try await control.connect(startIfNeeded: false, timeout: .seconds(3))
                    answered = true
                } catch {
                    // Refused as suspended (#1002): the window shows only that, and dials again.
                    self?.signIn.refused(error)
                    // The address itself refused (suspended, over a plan's limit, #2235):
                    // its words replace "can't reach", and trying again soon is pointless.
                    // `DaemonClient` keeps only "could not connect", so `ControlLink` kept
                    // the line on the side as it dialled.
                    if let line = ControlLink.hostedRefusal.take() {
                        self?.controlPlaneRefusalLine = line
                        backoff.holdOff()
                    }
                    answered = false
                }
                if answered {
                    backoff.connected()
                    self?.controlPlaneDidAnswer()
                    await self?.syncControlHosts(control)
                    await self?.loadKept(control)
                    await self?.people.connected(control)
                    await self?.signIn.connected(control)
                    // Status ▸ Secrets and Accounts' rows say when the newest operation was (#4161).
                    await self?.userScope.load(control)
                    await self?.keepTimeZone()
                    // A change of this Mac's zone is the person's, while connected (#4818).
                    let zoneWatch = Task { [weak self] in
                        for await _ in NotificationCenter.default.notifications(named: .NSSystemTimeZoneDidChange) {
                            NSTimeZone.resetSystemTimeZone()
                            await self?.keepTimeZone()
                        }
                    }
                    defer { zoneWatch.cancel() }
                    if let client = ControlConfig.client { await self?.lock.connected(control, client: client) }
                    await Self.sealWaiting(on: control, lock: self?.lock)
                    for await note in control.notifications() {
                        if note.method == DaemonAPI.Notification.controlSealingWanted {
                            await Self.sealWaiting(on: control, lock: self?.lock)
                            continue
                        }
                        if await self?.people.heard(note.method, note.params, on: control) == true { continue }
                        if self?.signIn.heard(note.method, note.params) == true { continue }
                        if await self?.lock.heard(note.method, note.params, on: control) == true {
                            // A machine just added to the lock may now be sealed to (#3491, D8).
                            if note.method == DaemonAPI.Notification.controlLockChanged { await Self.sealWaiting(on: control, lock: self?.lock) }
                            continue
                        }
                        if await self?.userScope.heard(note.method, note.params, on: control) == true {
                            // The host writes what it is sent a moment later: its panes read again.
                            try? await Task.sleep(for: .milliseconds(500))
                            await self?.refreshCostState()
                            await self?.refreshLeases()
                            continue
                        }
                        switch note.method {
                        case DaemonAPI.Notification.controlKeptChanged, DaemonAPI.Notification.controlKeptDelivered:
                            await self?.heardKept(note.method, note.params)
                        case DaemonAPI.Notification.controlHostChanged:
                            self?.hostCameOnline(note.params)
                            await self?.syncControlHosts(control)
                        case DaemonAPI.Notification.controlProvidersChanged:
                            // The Machines header's New Machine on ▸ and its default (#3979), and the
                            // machines that have not joined (#4978).
                            if let listed = try? note.params?["providers"]?.decode([DaemonAPI.ProviderSummary].self) {
                                self?.listedProviders = listed.filter(\.usable)
                            }
                        case DaemonAPI.Notification.controlInstallProgress:
                            // A join from the Machines group says its step on its row (#4978).
                            self?.heardInstallStep(note.params)
                        case DaemonAPI.Notification.controlLineageChanged:
                            // Work ▸ Timeline reads the sessions again (#4276).
                            self?.lineageChanges += 1
                        case DaemonAPI.Notification.controlThisMacHostChanged:
                            // The join file changed and the host list may not have (#303).
                            await self?.refreshMacHostJoin(control)
                        case DaemonAPI.Notification.controlConnectWanted:
                            // The page this Mac serves asked for Connect to Another… (#4257).
                            if let self { Task { await ConnectAnotherWanted.heard(note.params, on: control, model: self) } }
                        case DaemonAPI.Notification.controlPlaneMoveWanted:
                            // A page asked for a step of Move to Another Machine… or Run It Here Again… (#4255).
                            Task { await PlaneMoveWanted.heard(note.params, on: control) }
                        default:
                            break
                        }
                    }
                    if !Task.isCancelled { self?.controlPlaneWent() }
                } else if !Task.isCancelled {
                    self?.controlPlaneWent()
                }
                await backoff.wait()
            }
        }
    }

    /// A host is back, said by the control plane: a window still waiting out its backoff
    /// goes back now, rather than up to half a minute after the host returned (#172). One
    /// dial each, when there is something to reach, in place of a dial every 100 ms.
    func hostCameOnline(_ params: JSONValue?) {
        guard !isConnected, DaemonAPI.ControlMachine.answers(params?["state"]?.stringValue) else { return }
        backoff.nudge()
    }

    /// Seals what waits for a copy this window can make (#3397): a machine that joined, or a
    /// client paired, after an org route or one of the person's secrets was sealed.
    static func sealWaiting(on control: DaemonClient, lock: LockState?) async {
        // Only to the machines the lock names (#3491, D8).
        guard let lock else { return }
        guard let (key, client) = ControlConfig.sealing() else { return }
        await ClientSealing.sealWaiting(on: control, key: key, client: client) { await lock.signed($0, on: control) }
    }

    func controlPlaneDidAnswer() {
        controlPlaneReadAt = Date()
        controlPlaneReachable = true
        controlPlaneMissed = false
        controlPlaneRefusalLine = nil
    }

    func controlPlaneWent() {
        guard controlLink != nil else { return }
        people.went()
        signIn.went()
        lock.went()
        if controlPlaneReachable { controlPlaneReadAt = Date() }
        controlPlaneReachable = false
        controlPlaneMissed = true
    }

    /// The host's own join changed (#303). A host that just connected is dialled now,
    /// rather than at the end of the window's backoff.
    func refreshMacHostJoin(_ control: DaemonClient) async {
        guard let status = try? await control.call(DaemonAPI.Method.controlStatus, returning: DaemonAPI.ControlStatus.self) else { return }
        let connected = status.thisMacHost?.connected == true
        OlderPeer.controlVersion = status.version
        macHostJoin = status.thisMacHost
        controlPlaneMachine = status.machineID
        if connected, !isConnected { backoff.nudge() }
    }

    /// Start on the strip of a host linked to a stopped workspace (#691): the control plane
    /// asks its provider, and says how it goes as `control/hostChanged`.
    func startHost(_ host: MachineRef) async {
        guard let controlRequests, !hostsBeingStarted.contains(host) else { return }
        hostsBeingStarted.insert(host)
        defer { hostsBeingStarted.remove(host) }
        do {
            _ = try await controlRequests.call(DaemonAPI.Method.hostsStart, DaemonAPI.MachineRequest(host: host))
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached, so \(hosts.label(host)) can’t be started."
        }
    }

    /// Stop on a machine's row (#3973). Unconfirmed while agents work there, the control plane
    /// says who they are, and they are returned for the question; nil once it is stopping or refused.
    func stopHost(_ host: MachineRef, confirmed: Bool = false) async -> [String]? {
        guard let controlRequests else { return nil }
        do {
            _ = try await controlRequests.call(DaemonAPI.Method.hostsStop,
                                               DaemonAPI.MachineStop(host: host, confirmRunning: confirmed ? true : nil))
        } catch let error as JSONRPCError where error.code == DaemonAPI.Failure.agentsWorking {
            let names = error.data?["running"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !names.isEmpty { return names }
            problem = HostProblem.controlRefusal(error)
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached, so \(hosts.label(host)) can’t be stopped."
        }
        return nil
    }

    /// Delete… on a machine a provider made (#3973): the provider deletes it, then the host
    /// goes as Remove does.
    func deleteMachine(_ host: MachineRef) async {
        await machineCall(DaemonAPI.Method.hostsDeleteMachine, host)
    }

    /// Remove… on a registered machine (#3973): Agents forgets it; the computer stays.
    func removeMachine(_ host: MachineRef) async {
        await machineCall(DaemonAPI.Method.hostsRemove, host)
    }

    func machineCall(_ method: String, _ host: MachineRef) async {
        await controlCall(method, DaemonAPI.MachineRequest(host: host))
    }

    func controlCall(_ method: String, _ params: some Encodable & Sendable) async {
        guard let controlRequests else { return }
        do {
            _ = try await controlRequests.call(method, params)
            await syncControlHosts(controlRequests)
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached."
        }
    }

    /// New Machine (#3973, #4634): the sheet, on the default provider or the one New
    /// Machine on ▸ names, with every field on what New Machine would make (the options
    /// used last there, else its first choices) and the next `machine-N`. Make confirms it.
    func newMachine(on provider: ProviderID? = nil) {
        newMachineAsk = NewMachineAsk(provider: provider)
    }

    /// The New Machine sheet's form (#4634): the provider's schema and the values to start with.
    func newMachineForm(_ provider: ProviderID?) async -> Result<DaemonAPI.ProviderOptions, NewMachineRefusal> {
        guard let controlRequests else { return .failure(.init("The control plane can’t be reached.")) }
        do {
            return .success(try await controlRequests.call(DaemonAPI.Method.providersOptions, DaemonAPI.ProviderRequest(id: provider),
                                                           returning: DaemonAPI.ProviderOptions.self))
        } catch let error as JSONRPCError {
            return .failure(.init(HostProblem.controlRefusal(error)))
        } catch {
            return .failure(.init("The control plane can’t be reached, so no machine can be made."))
        }
    }

    /// Make on the New Machine sheet (#4634): the sheet closes at once and a *Making…* row
    /// takes over (#4610). A make the provider refuses opens the sheet again on the same
    /// choices, with the provider's reason, to change one and try again.
    func makeMachine(_ draft: NewMachineDraft) {
        guard let controlRequests else { return }
        machinesBeingMade += 1
        Task {
            defer { machinesBeingMade -= 1 }
            var refused: String?
            do {
                let made = try await controlRequests.call(
                    DaemonAPI.Method.providersCreate,
                    DaemonAPI.ProviderCreate(id: draft.provider, name: draft.name, options: .object(draft.values)),
                    returning: DaemonAPI.ProviderCreated.self)
                if made.workspace.state == "failed" {
                    refused = made.workspace.reason ?? "\(made.workspace.name) could not be made."
                }
            } catch let error as JSONRPCError {
                refused = HostProblem.controlRefusal(error)
            } catch {
                refused = "The control plane can’t be reached, so no machine can be made."
            }
            if let refused { newMachineAsk = NewMachineAsk(provider: draft.provider, again: draft, problem: refused) }
            await loadMachineProviders()
        }
    }

    /// The machines New Machine made that have not joined yet (#4610): a *Making…* row each
    /// under Machines, red with the reason once the control plane gave up on one; and every other
    /// machine of the person's that has not joined, grey, a click to join it (#4978).
    var machinesMaking: [MachineMaking] {
        MachineMaking.rows(listedProviders, hostNames: Set(hosts.controlRows.values.map(\.name)))
    }

    /// Delete on a row the control plane gave up on (#4610): the provider deletes the workspace.
    func deleteWorkspace(_ provider: ProviderID, workspace: String) async {
        guard let controlRequests else { return }
        do {
            _ = try await controlRequests.call(DaemonAPI.Method.providersDeleteWorkspace,
                                               DaemonAPI.ProviderWorkspaceRequest(id: provider, workspace: workspace))
        } catch let error as JSONRPCError {
            problem = HostProblem.controlRefusal(error)
        } catch {
            problem = "The control plane can’t be reached, so the machine wasn’t deleted."
        }
        await loadMachineProviders()
    }

    /// The providers New Machine can use (#3979), for the Machines header's menu.
    func loadMachineProviders() async {
        guard let controlRequests,
              let answer = try? await controlRequests.call(DaemonAPI.Method.providersList, DaemonAPI.Empty()),
              let listed = try? answer["providers"]?.decode([DaemonAPI.ProviderSummary].self)
        else { return }
        listedProviders = listed.filter(\.usable)
    }

    /// A click on a machine that never joined (#4978): the control plane installs Agents on it
    /// over ssh, from the machine that carries its provider for a codespace (`gh codespace ssh`
    /// starts a stopped one), after starting it with its provider otherwise. The row says each
    /// step, and why it failed; it leaves when the machine joins. `trust` is a host key the
    /// person looked at and trusts.
    func joinMachine(_ row: MachineMaking, trust: String? = nil) async {
        guard row.canJoin, machineJoins[row.id]?.isJoining != true, let controlRequests, let ssh = row.ssh else { return }
        machineJoins[row.id] = .joining(step: nil)
        var params: [String: JSONValue] = ["destination": .string(ssh), "name": .string(row.name),
                                           "tunnel": .bool(row.tunnel), "provider": .string(row.provider.rawValue),
                                           "workspace": .string(row.workspace)]
        if let trust { params["trust"] = .string(trust) }
        do {
            let answer = try await controlRequests.call(DaemonAPI.Method.hostsInstall, JSONValue.object(params))
            if let fingerprint = answer["needsTrust"]?.stringValue {
                machineJoins[row.id] = .needsTrust(fingerprint)
            } else {
                machineJoins[row.id] = .joining(step: "started")
            }
        } catch let error as JSONRPCError {
            machineJoins[row.id] = .failed(HostProblem.controlRefusal(error))
        } catch {
            machineJoins[row.id] = .failed("The control plane can’t be reached.")
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

    /// Delete's question on a machine's row (#3979): the worktrees on it with work not
    /// pushed. Nil when the control plane can't say (an older one).
    func deletePreview(_ host: MachineRef) async -> DaemonAPI.StartedMachinePreview? {
        try? await controlRequests?.call(DaemonAPI.Method.hostsDeletePreview, DaemonAPI.MachineRequest(host: host),
                                         returning: DaemonAPI.StartedMachinePreview.self)
    }

    /// Check Again on a machine's row (#3979), as Settings ▸ Machines had it.
    func checkAgain(_ host: MachineRef) async {
        await machineCall(DaemonAPI.Method.hostsCheckAgain, host)
    }

    /// Unlink on a machine's page (#3975): its provider can no longer start or stop it.
    func unlinkMachine(_ host: MachineRef) async {
        await machineCall(DaemonAPI.Method.hostsUnlink, host)
    }

    /// Start when used, Start for scheduled workflows and Stop when idle on a machine's page
    /// (#3975), as Settings ▸ Machines' menu had them. `stopWhenIdleMinutes` 0 turns it off.
    func setMachineOptions(_ host: MachineRef, startWhenUsed: Bool? = nil, stopWhenIdleMinutes: Int? = nil,
                           startForSchedules: Bool? = nil) async {
        await controlCall(DaemonAPI.Method.hostsSetMachineOptions,
                          DaemonAPI.MachineOptions(host: host, startWhenUsed: startWhenUsed,
                                                   stopWhenIdleMinutes: stopWhenIdleMinutes,
                                                   startForSchedules: startForSchedules))
    }

    /// Stop Lending on a machine's page (#1122, #3975): it stops using a Mac's git access for one server.
    func stopLendingGit(_ host: MachineRef, from: MachineRef, server: String) async {
        await controlCall(DaemonAPI.Method.hostsLendGit,
                          DaemonAPI.LendGit(host: host, from: from, server: server, allowed: false))
    }

    /// Approve or Deny on a machine's card (#994): a refusal is the window's alert.
    func answerJoin(_ request: DaemonAPI.JoinRequest, approve: Bool) async {
        if let refused = await people.answer(request, approve: approve, on: controlRequests) {
            problem = refused
        }
    }

    /// Approve or Deny on a GitHub sign-in's card (#995): a refusal is the window's alert.
    func answerSignIn(_ request: DaemonAPI.SignInRequest, approve: Bool, code: String? = nil) async {
        if let refused = await signIn.answer(request, approve: approve, code: code, on: controlRequests) {
            problem = refused
        }
    }

    /// Compare Digits, Approve or Deny on a lock card, and Ask Again on this window's own (#3490).
    func compareLock(_ request: DaemonAPI.LockJoinRequest) async { await lock.compare(request, on: controlRequests) }
    func approveLock(_ request: DaemonAPI.LockJoinRequest) async { await lock.approve(request, on: controlRequests) }
    func denyLock(_ request: DaemonAPI.LockJoinRequest) async { await lock.deny(request, on: controlRequests) }
    func askLockAgain() async { await lock.askAgain(on: controlRequests) }
    /// The recovery key (#3493, D4): Use Recovery Key, Start a New Lock, Make Recovery Key, and
    /// I Saved It or Skip.
    func useLockRecovery(_ text: String) async -> String? { await lock.useRecoveryKey(text, on: controlRequests) }
    func startNewLock() async { await lock.startNewLock(on: controlRequests) }
    func makeLockRecovery() async { await lock.makeRecoveryKey(on: controlRequests) }
    func dismissLockRecovery() { lock.dismissRecovery() }

    /// Approve, Deny or Send on a channel link's card (#1762): a refusal is the window's alert.
    func answerLink(_ request: DaemonAPI.ChannelLinkRequest, approve: Bool, to person: String?) async {
        if let refused = await people.answerLink(request, approve: approve, to: person, on: controlRequests) {
            problem = refused
        }
    }
}
