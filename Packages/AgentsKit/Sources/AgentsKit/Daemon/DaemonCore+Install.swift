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
        if discovery.locate(runtime).isAvailable {
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
        return status
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
