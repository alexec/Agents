import AgentsKit
import AgentsKitCore
import Foundation
import ServiceManagement

/// This Mac's host and the single copy of the control plane, kept running by macOS (058,
/// T055; moved here from the window, which runs nothing now).
///
/// `agentsd` is always registered once a role is chosen; `agents-control` only while
/// *Run it here* is on; `agents-relay` only while *Relay for my devices* is (#809). On the ordinary set-up both are launch agents in the bundle,
/// registered with `SMAppService`: they show under Login Items as Agents Host, and
/// registering again finds them registered (US2-4: nothing twice).
///
/// A scratch set-up writes plists of its own into its root, labelled with the root's hash,
/// bootstraps them with `launchctl` and boots them out again in `remove`.
struct LocalServices {
    let paths: HostPaths

    enum Outcome: Equatable {
        case enabled
        /// macOS wants the person to allow it in System Settings ▸ Login Items.
        case needsApproval
        case failed(String)
    }

    enum Job { case control, daemon, relay }

    // MARK: Registering

    func register(_ job: Job) async -> Outcome {
        paths.scratch ? await bootstrap(job) : registerWithSystem(job)
    }

    func unregister(_ job: Job) async {
        if paths.scratch {
            _ = await Self.launchctl(["bootout", "gui/\(getuid())/\(label(job))"])
        } else {
            try? await SMAppService.agent(plistName: plist(job)).unregister()
        }
    }

    /// The program this copy's plist names for it, as launchd prints it: `BundleProgram`.
    func bundledProgram(_ job: Job) -> String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchAgents/\(plist(job))")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist["BundleProgram"] as? String
    }

    /// Registered, and launchd runs another program than this copy's plist names (#1379).
    /// An update keeps a login item's registration, and `register` finds it enabled: a Mac
    /// registered before #1138 ran `Helpers/agentsd` straight, never the launcher.
    func registeredFromAnotherPlist(_ job: Job) async -> Bool {
        guard !paths.scratch, loginStatus(job) == .enabled, let wanted = bundledProgram(job),
              let program = await state(job).program else { return false }
        return program != wanted
    }

    /// Unregistered and registered again from this copy's plist; launchd starts it again.
    func registerAgain(_ job: Job) async -> Outcome {
        await unregister(job)
        for _ in 0..<20 where await state(job).loaded { try? await Task.sleep(for: .milliseconds(250)) }
        return await register(job)
    }

    func remove() async {
        await unregister(.control)
        await unregister(.daemon)
        await unregister(.relay)
    }

    /// launchd stops it and starts it again at once. Every client and host redials.
    func restart(_ job: Job) async -> Bool {
        await Self.launchctl(["kickstart", "-k", "gui/\(getuid())/\(label(job))"]) == 0
    }

    /// Whether launchd has it running, and as which process.
    func running(_ job: Job) async -> Int32? {
        let state = await state(job)
        return state.running ? state.pid : nil
    }

    /// What launchd says of it (#678): running, or why not.
    func state(_ job: Job) async -> LaunchJobState {
        let printed = await Self.run(["print", "gui/\(getuid())/\(label(job))"])
        return LaunchJobState.parse(printed.text, exitStatus: printed.status)
    }

    /// `launchctl print` as it is, for the diagnostics.
    func printed(_ job: Job) async -> String {
        let printed = await Self.run(["print", "gui/\(getuid())/\(label(job))"])
        return printed.status == 0 ? printed.text : printed.text + printed.errorText
    }

    /// Its login item, as `SMAppService` has it. A scratch set-up has none.
    func loginStatus(_ job: Job) -> LoginItemStatus {
        guard !paths.scratch else { return .scratch }
        switch SMAppService.agent(plistName: plist(job)).status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    /// Leave a one-time host code where `agentsd` reads it: on its next start, and on each
    /// try to join until one has worked (#113).
    func leaveCode(_ code: String) throws {
        try FileManager.default.createDirectory(at: paths.hostRoot, withIntermediateDirectories: true)
        let file = paths.hostLocations.controlJoinCode
        do {
            try StoreCoding.writeAtomically(Data(code.utf8), to: file, permissions: 0o600)
        } catch {
            // Said as what it is (#212): a full disk is not a code refused.
            throw ControlService.Failure(WriteFailure(error, keeping: "the code for the machine on this Mac")?.message
                ?? "could not leave the code for the machine on this Mac: \(error.localizedDescription)")
        }
    }

    /// Whether this Mac's host has joined a control plane already.
    var hostJoined: Bool { ControlMembership.load(paths.hostLocations.controlHostMembership) != nil }

    func label(_ job: Job) -> String {
        switch job {
        case .control: paths.controlLabel
        case .daemon: paths.daemonLabel
        case .relay: paths.relayLabel
        }
    }

    private func plist(_ job: Job) -> String {
        switch job {
        case .control: HostPaths.controlPlist
        case .daemon: HostPaths.daemonPlist
        case .relay: HostPaths.relayPlist
        }
    }

    /// Leave the relay a one-time host code where it reads it on its next start (#809).
    func leaveRelayCode(_ code: String) throws {
        let files = paths.relayFiles
        do {
            try FileManager.default.createDirectory(at: files.folder, withIntermediateDirectories: true)
            try StoreCoding.writeAtomically(Data(code.utf8), to: files.joinCode, permissions: 0o600)
        } catch {
            throw ControlService.Failure(WriteFailure(error, keeping: "the relay's code")?.message
                ?? "could not leave the relay its code: \(error.localizedDescription)")
        }
    }

    /// The relay host this Mac's relay joined as, once it has.
    var relayHost: MachineRef? { ControlMembership.load(paths.relayFiles.membership)?.host }

    /// The relay's enrolment, and any code left for it, gone: it joins again only with a
    /// new code (#824). Its key stays.
    func forgetRelayMembership() {
        let files = paths.relayFiles
        try? FileManager.default.removeItem(at: files.membership)
        try? FileManager.default.removeItem(at: files.joinCode)
    }

    private func registerWithSystem(_ job: Job) -> Outcome {
        let service = SMAppService.agent(plistName: plist(job))
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .needsApproval
        default: break
        }
        do {
            try service.register()
        } catch {
            if service.status == .requiresApproval { return .needsApproval }
            return .failed("macOS would not start \(plist(job)): \(error.localizedDescription)")
        }
        return service.status == .requiresApproval ? .needsApproval : .enabled
    }

    // MARK: A scratch set-up's own jobs

    private func bootstrap(_ job: Job) async -> Outcome {
        let path = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:\(NSHomeDirectory())/.local/bin"
        let environment = ProcessInfo.processInfo.environment
        let arguments: [String]
        var variables: [String: String]
        switch job {
        case .control:
            guard let program = Bundle.main.executableURL?.path else { return .failed("no program to launch") }
            arguments = [program, ControlLauncher.argument]
            variables = [StoreLocations.rootVariable: environment[StoreLocations.rootVariable] ?? "", "PATH": path]
            for name in ["AGENTS_HOST_PORT", "AGENTS_HOST_WEB_PORT", "AGENTS_HOST_BONJOUR"] { variables[name] = environment[name] }
        case .daemon:
            // Named here (#1138): a scratch job's launcher would take the host's root for the
            // set-up's.
            arguments = [paths.agentsd.path, "--control-network"]
                + DaemonLauncher.pageArguments(HostSettings.load(paths), paths: paths)
                + DaemonLauncher.pinArguments()
            variables = [StoreLocations.rootVariable: paths.hostRoot.path, "PATH": path]
        case .relay:
            // `<root>/relay`, and a walk's folder standing in for iCloud when it gives one.
            arguments = [paths.agentsRelay.path]
            variables = [StoreLocations.rootVariable: paths.scratchRoot?.path ?? "", "PATH": path]
            if let stand = environment["AGENTS_RELAY_FOLDER"] { variables["AGENTS_RELAY_FOLDER"] = stand }
        }
        #if DEBUG
        // A walk's stand-in for a public root (#61, Pebble), for the host to follow a move.
        if let root = environment["AGENTS_TEST_TRUST_ROOT"] { variables["AGENTS_TEST_TRUST_ROOT"] = root }
        #endif
        guard FileManager.default.isExecutableFile(atPath: arguments[0]) else {
            return .failed("This copy of Agents Host has no \(URL(fileURLWithPath: arguments[0]).lastPathComponent) in it.")
        }
        let folder = switch job {
        case .control: paths.controlHome
        case .daemon: paths.hostRoot
        case .relay: paths.relayFiles.folder
        }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "Label": label(job),
            "ProgramArguments": arguments,
            "EnvironmentVariables": variables,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
        ]
        if job == .daemon {
            plist["StandardOutPath"] = paths.hostOut.path
            plist["StandardErrorPath"] = paths.hostOut.path
        }
        let file = folder.appendingPathComponent("\(label(job)).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: file, options: .atomic)
        } catch {
            return .failed("Could not write \(file.lastPathComponent): \(error.localizedDescription)")
        }
        // Loaded already is running already: nothing is started twice.
        if await Self.launchctl(["print", "gui/\(getuid())/\(label(job))"]) == 0 { return .enabled }
        let outcome = await Self.run(["bootstrap", "gui/\(getuid())", file.path])
        if outcome.timedOut { return .failed("launchctl did not finish starting \(label(job)) in 30 seconds and was stopped.") }
        return outcome.status == 0 ? .enabled : .failed("launchctl could not start \(label(job)) (\(outcome.status)).")
    }

    // MARK: launchctl

    /// Read as it writes, so a `print` of a busy domain bigger than the pipe cannot stall
    /// it, and stopped at a deadline (#92). See `ChildProcess`.
    private static func launchctl(_ arguments: [String]) async -> Int32 {
        await run(arguments).status
    }

    private static func run(_ arguments: [String]) async -> ChildProcess.Outcome {
        await ChildProcess.run(URL(fileURLWithPath: "/bin/launchctl"), arguments)
    }
}
