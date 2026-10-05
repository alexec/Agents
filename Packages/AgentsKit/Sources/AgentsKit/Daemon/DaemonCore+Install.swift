import Foundation

/// Installing a runtime that is missing (048).
///
/// Started here and left running: the call answers at once with `.installing`, and the
/// progress and the ending go out on `runtime/changed`, so a window that opens halfway
/// through sees the same state as the one that pressed the button.
extension DaemonCore {
    func installRuntime(_ runtimeID: String, from surface: Surface?) throws -> RuntimeStatus {
        guard let runtime = RuntimeCatalog.runtime(id: runtimeID) else {
            throw JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound,
                               message: "There is no runtime called \(runtimeID).")
        }
        // A server keeps 043's own toolset install. And a phone asks the Mac to fetch and
        // run a vendor's script nowhere in this lane: installing is the Mac window's.
        guard let installer, installer.recipe(for: runtime) != nil else {
            throw JSONRPCError(code: DaemonAPI.Failure.notSupported,
                               message: "\(runtime.name) can’t be installed from here. Install it from \(runtime.installPage.absoluteString).")
        }
        if case .device = surface {
            throw JSONRPCError(code: DaemonAPI.Failure.notSupported,
                               message: "Install \(runtime.name) from the Mac.")
        }
        if installs[runtimeID] != nil { return status(of: runtime) }
        // Here, and the toolset this app carries: nothing to do. Here but outdated is what
        // **Update** asks for, and installs the new one beside the old (047).
        if discovery.locate(runtime).isAvailable, !discovery.isOutdated(runtime) {
            installStates[runtimeID] = nil
            return status(of: runtime)
        }
        DaemonLog.shared.write("installing \(runtimeID)")
        setInstallState(.installing(progress: nil), for: runtime)
        installs[runtimeID] = Task { [weak self] in
            let result = await installer.install(runtime) { [weak self] step in
                Task { await self?.installProgressed(runtimeID, step) }
            }
            await self?.installFinished(runtime, result)
        }
        return status(of: runtime)
    }

    /// Why `runtime` cannot be started, when an install is under way or failed (047,
    /// FR-003): said instead of "not installed", which would be untrue while it is being
    /// installed and unhelpful after the install said why. Nil otherwise.
    func notYetInstalled(_ runtime: Runtime) -> String? {
        if installs[runtime.id] != nil { return "\(runtime.name) is still being installed. Try again when it is." }
        if case .installFailed(let reason)? = installStates[runtime.id] {
            return "\(runtime.name) isn’t installed: \(reason)"
        }
        return nil
    }

    /// The overlay `runtimes/list` draws: what an install says, over what discovery sees.
    func overlaid(_ status: RuntimeStatus) -> RuntimeStatus {
        var status = status
        // The button is offered only where this daemon can carry it out.
        status.runtime.install = installer?.recipe(for: status.runtime)
        if let state = installStates[status.runtime.id] {
            if state.isInstalling || !status.availability.isAvailable {
                status.availability = state
            }
        }
        status.outdated = status.availability.isAvailable && discovery.isOutdated(status.runtime)
        status.poolNote = poolNote(runtimeID: status.runtime.id)
        status.isOut = isOutOfPool(runtimeID: status.runtime.id) ? true : nil
        return status
    }

    /// Why an agent cannot start on `runtime` right now, said the way its set-up row says
    /// it (046, FR-003): being installed, failed to install, or not here with the place to
    /// install it. The error the start and pick-up paths throw instead of launching.
    func notStartable(_ runtime: Runtime, lookedIn: [String]) -> JSONRPCError {
        let recipe = installer?.recipe(for: runtime)
        let message = notYetInstalled(runtime)
            ?? (recipe != nil ? "\(runtime.name) isn’t on this Mac. Install it from Settings ▸ Agent Runtimes."
                              : "\(runtime.name) is not installed, or is not where we looked.")
        return JSONRPCError(code: DaemonAPI.Failure.runtimeNotFound, message: message,
                            data: ["lookedIn": .array(lookedIn.map(JSONValue.string))])
    }

    /// Wait for an install under way to end. For tests; the app listens instead.
    func waitForInstall(_ runtimeID: String) async {
        await installs[runtimeID]?.value
    }

    private func installProgressed(_ runtimeID: String, _ step: String) {
        // A step that lands after the ending would draw a spinner over the result.
        guard installs[runtimeID] != nil, let runtime = RuntimeCatalog.runtime(id: runtimeID) else { return }
        setInstallState(.installing(progress: step), for: runtime)
    }

    private func installFinished(_ runtime: Runtime, _ result: RuntimeAvailability) {
        installs[runtime.id] = nil
        if result.isAvailable {
            DaemonLog.shared.write("installed \(runtime.id)")
            installStates[runtime.id] = nil
            // A warm runtime is the version before (#183).
            Task { await self.releaseWarm(runtimeID: runtime.id, because: "\(runtime.id) was updated") }
            broadcast(DaemonAPI.Notification.runtimeChanged, status(of: runtime))
        } else {
            DaemonLog.shared.write("installing \(runtime.id) failed: \(result)")
            setInstallState(result, for: runtime)
        }
    }

    private func setInstallState(_ state: RuntimeAvailability, for runtime: Runtime) {
        installStates[runtime.id] = state
        broadcast(DaemonAPI.Notification.runtimeChanged, status(of: runtime))
    }

    private func status(of runtime: Runtime) -> RuntimeStatus {
        overlaid(RuntimeStatus(runtime: runtime, availability: discovery.locate(runtime)))
    }
}
