import AgentsKitCore
import Foundation

/// What this Mac's host's launch agent runs: this app's own program with
/// `--launch-daemon` (#1138). It becomes the bundle's `agentsd` (Go since #1312, the only
/// one since #1314), with the rest of its arguments. launchd keeps it running.
enum DaemonLauncher {
    static let argument = "--launch-daemon"

    static func run() -> Never {
        let paths = HostPaths.current
        let tool = paths.agentsd.path
        let rest = Array(CommandLine.arguments.dropFirst().filter { $0 != argument })
            + pageArguments(HostSettings.load(paths), paths: paths)
            + pinArguments()
        let argv = ([tool] + rest).map { strdup($0) } + [nil]
        execv(tool, argv)
        FileHandle.standardError.write(Data("Agents Host: could not start \(tool): \(String(cString: strerror(errno)))\n".utf8))
        // Not at once again: launchd would restart a failure in a tight loop.
        sleep(10)
        exit(1)
    }

    /// The pin the organisation's configuration profile sets (#998, US7), for agentsd to
    /// keep to; a key the profile forces that is no pin's is let go, and said in the log.
    static func pinArguments() -> [String] {
        let pin = MachinePin.managed(ignored: { keys in
            FileHandle.standardError.write(Data("Agents Host: the profile's \(keys.joined(separator: ", ")) ignored: rules come only from the control plane\n".utf8))
        })
        return pin?.arguments ?? []
    }

    /// The web page for agentsd to serve on loopback (#1480, #1952): only when the control
    /// plane runs elsewhere, so this Mac runs none to serve it, and the person serves Agents
    /// to browsers on this Mac. With the control plane here, its own listener serves it.
    static func pageArguments(_ settings: HostSettings, paths: HostPaths) -> [String] {
        guard settings.role == .joinElsewhere, settings.servesWebRemote else { return [] }
        return ["--web", paths.webRemote.path, "--web-port", String(paths.webPort)]
    }
}
