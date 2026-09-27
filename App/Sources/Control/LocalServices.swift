import AgentsKit
import AgentsKitCore
import Foundation
import ServiceManagement

/// The control plane and this Mac's host, kept running by macOS (058, R5).
///
/// On the ordinary root, the two launch agents in the bundle are registered with
/// `SMAppService`: they show under Login Items as the app, and live and die with it.
///
/// A scratch root must never touch those, so it gets two jobs of its own: plists written
/// into its own folder, labelled with the root's hash, bootstrapped with `launchctl` and
/// booted out again by `remove`. Nothing of a walk is left in `~/Library/LaunchAgents`.
struct LocalServices {
    let hostRoot: URL
    let controlRoot: URL
    let scratch: Bool

    /// For the window's own root: the ordinary control root with the ordinary root, a
    /// `control` folder inside a scratch root with a scratch one.
    static var forThisWindow: LocalServices {
        let locations = StoreLocations.default
        if locations.isStandard {
            return LocalServices(hostRoot: locations.root, controlRoot: ControlPlane.defaultRoot, scratch: false)
        }
        return LocalServices(hostRoot: locations.root,
                             controlRoot: locations.root.appendingPathComponent("control", isDirectory: true),
                             scratch: true)
    }

    static let controlPlist = "com.alexecollins.agents.control.plist"
    static let hostPlist = "com.alexecollins.agents.host.plist"
    static let hostOnlyPlist = "com.alexecollins.agents.hostonly.plist"

    enum Approval: Equatable {
        case enabled
        /// macOS wants the person to allow it in System Settings ▸ Login Items.
        case needsApproval
        case failed(String)
    }

    // MARK: Registering

    /// Registers both, or finds them registered already (US2.4: nothing is installed twice).
    func register() async -> Approval {
        scratch ? await bootstrapScratch() : registerWithSystem()
    }

    /// Takes both away again. Only walks and tests call this for now.
    func remove() async {
        if scratch {
            for label in [controlLabel, hostLabel, hostOnlyLabel] { _ = await Self.launchctl(["bootout", "gui/\(getuid())/\(label)"]) }
        } else {
            try? await SMAppService.agent(plistName: Self.hostOnlyPlist).unregister()
            try? await SMAppService.agent(plistName: Self.hostPlist).unregister()
            try? await SMAppService.agent(plistName: Self.controlPlist).unregister()
        }
    }

    /// Restart the control plane: launchd stops it and starts it again at once. Every
    /// client and host reconnects by itself (frame D's Restart).
    func restartControlPlane() async -> Bool {
        await Self.launchctl(["kickstart", "-k", "gui/\(getuid())/\(controlLabel)"]) == 0
    }

    /// Only this Mac's host, for a control plane elsewhere (058, US7). The membership is
    /// already in the host root; the daemon dials out with it.
    func registerHostOnly() async -> Approval {
        scratch ? await bootstrapScratch(hostOnly: true) : registerWithSystem([Self.hostOnlyPlist])
    }

    /// Which machine this host says it is. A scratch root stands in for another Mac, so
    /// it says a machine of its own, or the control plane would take it for this one's.
    var machineID: String { scratch ? "scratch-\(suffix)" : MachineID.current }
    var hostName: String { scratch ? "Scratch Mac \(suffix.prefix(4))" : Host.current().localizedName ?? "A Mac" }

    private func registerWithSystem(_ names: [String] = [Self.controlPlist, Self.hostPlist]) -> Approval {
        var needsApproval = false
        for name in names {
            let service = SMAppService.agent(plistName: name)
            switch service.status {
            case .enabled: continue
            case .requiresApproval: needsApproval = true; continue
            default: break
            }
            do {
                try service.register()
            } catch {
                if service.status == .requiresApproval { needsApproval = true; continue }
                return .failed("macOS would not start \(name): \(error.localizedDescription)")
            }
            if service.status == .requiresApproval { needsApproval = true }
        }
        return needsApproval ? .needsApproval : .enabled
    }

    // MARK: A scratch root's own jobs

    private var suffix: String {
        let hash = hostRoot.standardizedFileURL.path.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return String(hash, radix: 16).suffix(8).description
    }

    var controlLabel: String { scratch ? "com.alexecollins.agents.control.scratch-\(suffix)" : "com.alexecollins.agents.control" }
    var hostLabel: String { scratch ? "com.alexecollins.agents.host.scratch-\(suffix)" : "com.alexecollins.agents.host" }
    var hostOnlyLabel: String { scratch ? "com.alexecollins.agents.hostonly.scratch-\(suffix)" : "com.alexecollins.agents.hostonly" }

    private func bootstrapScratch(hostOnly: Bool = false) async -> Approval {
        let helpers = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers")
        let bridge = helpers.appendingPathComponent("agents-bridge.app/Contents/MacOS/agents-bridge").path
        let agentsd = helpers.appendingPathComponent("agentsd").path
        guard FileManager.default.isExecutableFile(atPath: bridge), FileManager.default.isExecutableFile(atPath: agentsd) else {
            return .failed("This copy of Agents has no control plane in it.")
        }
        try? FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let jobs: [(String, [String], [String: String], String)] = hostOnly ? [
            (hostOnlyLabel, [agentsd, "--control-network", "--host-name", hostName],
             ["AGENTS_ROOT": hostRoot.path, "AGENTS_MACHINE_ID": machineID, "PATH": path],
             "host.out"),
        ] : [
            (controlLabel, [bridge],
             ["AGENTS_ROOT": hostRoot.path, ControlPlane.rootVariable: controlRoot.path,
              // Off the ordinary port, off Bonjour and out of iCloud: a walk is nobody's
              // phone, and a scratch bridge named like this Mac must never be the one the
              // person's phone finds first.
              "AGENTS_BRIDGE_PORT": "8799", "AGENTS_BRIDGE_NO_MAILBOX": "1", "AGENTS_BRIDGE_NO_BONJOUR": "1",
              ControlNet.portVariable: "8798", "PATH": path],
             "control.out"),
            (hostLabel, [agentsd, DaemonCommandLine.controlFlag, ControlPlane.hostSocket(root: controlRoot).path],
             ["AGENTS_ROOT": hostRoot.path, "PATH": path],
             "host.out"),
        ]
        for (label, arguments, environment, log) in jobs {
            let plist: [String: Any] = [
                "Label": label,
                "ProgramArguments": arguments,
                "EnvironmentVariables": environment,
                "RunAtLoad": true,
                "KeepAlive": true,
                "StandardOutPath": controlRoot.appendingPathComponent(log).path,
                "StandardErrorPath": controlRoot.appendingPathComponent(log).path,
            ]
            let file = controlRoot.appendingPathComponent("\(label).plist")
            do {
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: file, options: .atomic)
            } catch {
                return .failed("Could not write \(file.lastPathComponent): \(error.localizedDescription)")
            }
            // Already loaded is already running: nothing is started twice.
            if await Self.launchctl(["print", "gui/\(getuid())/\(label)"]) == 0 { continue }
            let status = await Self.launchctl(["bootstrap", "gui/\(getuid())", file.path])
            guard status == 0 else { return .failed("launchctl could not start \(label) (\(status)).") }
        }
        return .enabled
    }

    /// Ended on its termination handler, never `waitUntilExit`, which hangs off the main
    /// thread.
    private static func launchctl(_ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }
}
