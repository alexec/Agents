import AgentsKitCore
import Foundation
import ServiceManagement

/// This Mac's host and the single copy of the control plane, kept running by macOS (058,
/// T055; moved here from the window, which runs nothing now).
///
/// `agentsd` is always registered once a role is chosen; `agents-control` only while
/// *Run it here* is on. On the ordinary set-up both are launch agents in the bundle,
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

    enum Job { case control, daemon }

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

    func remove() async {
        await unregister(.control)
        await unregister(.daemon)
    }

    /// launchd stops it and starts it again at once. Every client and host redials.
    func restart(_ job: Job) async -> Bool {
        await Self.launchctl(["kickstart", "-k", "gui/\(getuid())/\(label(job))"]) == 0
    }

    /// Whether launchd has it running, and as which process.
    func running(_ job: Job) async -> Int32? {
        let text = await Self.launchctlOutput(["print", "gui/\(getuid())/\(label(job))"])
        guard text.contains("state = running") else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = "), let pid = Int32(trimmed.dropFirst(6)) { return pid }
        }
        return nil
    }

    /// Leave a one-time host code where `agentsd` reads it on its next start.
    func leaveCode(_ code: String) throws {
        try FileManager.default.createDirectory(at: paths.hostRoot, withIntermediateDirectories: true)
        let file = paths.hostLocations.controlJoinCode
        guard FileManager.default.createFile(atPath: file.path, contents: Data(code.utf8),
                                             attributes: [.posixPermissions: 0o600]) else {
            throw ControlService.Failure("could not leave the code for this Mac's host")
        }
    }

    /// Whether this Mac's host has joined a control plane already.
    var hostJoined: Bool { ControlMembership.load(paths.hostLocations.controlHostMembership) != nil }

    func label(_ job: Job) -> String { job == .control ? paths.controlLabel : paths.daemonLabel }
    private func plist(_ job: Job) -> String { job == .control ? HostPaths.controlPlist : HostPaths.daemonPlist }

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
            for name in ["AGENTS_HOST_PORT", "AGENTS_HOST_BONJOUR"] { variables[name] = environment[name] }
        case .daemon:
            arguments = [paths.agentsd.path, "--control-network"]
            variables = [StoreLocations.rootVariable: paths.hostRoot.path, "PATH": path]
        }
        guard FileManager.default.isExecutableFile(atPath: arguments[0]) else {
            return .failed("This copy of Agents Host has no \(URL(fileURLWithPath: arguments[0]).lastPathComponent) in it.")
        }
        let folder = job == .control ? paths.controlHome : paths.hostRoot
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "Label": label(job),
            "ProgramArguments": arguments,
            "EnvironmentVariables": variables,
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
        ]
        if job == .daemon {
            plist["StandardOutPath"] = paths.hostRoot.appendingPathComponent("host.out").path
            plist["StandardErrorPath"] = paths.hostRoot.appendingPathComponent("host.out").path
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
        let status = await Self.launchctl(["bootstrap", "gui/\(getuid())", file.path])
        return status == 0 ? .enabled : .failed("launchctl could not start \(label(job)) (\(status)).")
    }

    // MARK: launchctl

    /// Ended on its termination handler, never `waitUntilExit`, which hangs off the main
    /// thread.
    private static func launchctl(_ arguments: [String]) async -> Int32 {
        await run(arguments).status
    }

    private static func launchctlOutput(_ arguments: [String]) async -> String {
        await run(arguments).output
    }

    private static func run(_ arguments: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do { try process.run() } catch { continuation.resume(returning: (-1, "")) }
        }
    }
}
