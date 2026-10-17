import Foundation

/// What this Mac's host's launch agent runs: this app's own program with
/// `--launch-daemon` (#1138). It becomes the `agentsd` this Mac's settings pick, the Swift
/// one unless `host.json` says `"daemonImplementation": "go"` and the bundle carries the Go
/// one, with the rest of its arguments. launchd keeps it running.
enum DaemonLauncher {
    static let argument = "--launch-daemon"

    static func run() -> Never {
        let paths = HostPaths.current
        let tool = paths.agentsd(for: HostSettings.load(paths)).path
        // Which one ran is never a guess: the Go one's daemon.log says "(go)" as it starts.
        let rest = CommandLine.arguments.dropFirst().filter { $0 != argument }
        let argv = ([tool] + rest).map { strdup($0) } + [nil]
        execv(tool, argv)
        FileHandle.standardError.write(Data("Agents Host: could not start \(tool): \(String(cString: strerror(errno)))\n".utf8))
        // Not at once again: launchd would restart a failure in a tight loop.
        sleep(10)
        exit(1)
    }
}
