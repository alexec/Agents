import Foundation

/// The config files the app writes for a runtime that will read policy only off disk,
/// and the environment variables or launch arguments that point at them.
///
/// Two runtimes need this. Grok's feature switches are read from a file named by
/// `GROK_CONFIG_PATH` and nowhere else — the same TOML handed over inline was measured and
/// ignored — so scoping it means writing a file (Research R6, R11). Gemini's deny rules are
/// read from a file named by `--policy` (046, R5).
///
/// Under the daemon's own root, which is the daemon's identity: a second daemon on a
/// second root gets its own copy, exactly as every other file here does. Nothing goes
/// near `~/.grok`, and nothing is left behind that the app did not write for itself.
///
/// Rebuilt from the policy every launch rather than written once and trusted. It is
/// cheap, and it means a policy edited in the source is a policy in force the next time
/// an agent starts, without anybody remembering to delete anything.
public struct RuntimePolicyFiles: Sendable {
    let locations: StoreLocations

    public init(locations: StoreLocations) {
        self.locations = locations
    }

    /// `base` with one variable added per file in the policy, and the files written.
    ///
    /// A failure to write one is logged and carried past rather than thrown. A session
    /// that will not start is worse than a runtime that kept its image tools, and the
    /// check script is what notices the second — whereas nobody would thank us for an
    /// agent that refused to run because a temp directory was full.
    public func environment(for policy: ToolPolicy, onto base: [String: String]) -> [String: String] {
        var environment = base
        for file in policy.environmentFiles {
            guard let variable = file.variable, let path = write(file, for: policy) else { continue }
            environment[variable] = path
        }
        return environment
    }

    /// The flag and path for each file named by an argument, with the files written. Put
    /// after the runtime's own arguments. Carried past a failure to write, as above.
    public func arguments(for policy: ToolPolicy) -> [String] {
        policy.environmentFiles.flatMap { file -> [String] in
            guard let argument = file.argument, let path = write(file, for: policy) else { return [] }
            return [argument, path]
        }
    }

    private func write(_ file: EnvironmentFile, for policy: ToolPolicy) -> String? {
        let directory = locations.root.appendingPathComponent("runtimes", isDirectory: true)
        let url = directory.appendingPathComponent(file.name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try file.contents.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        } catch {
            DaemonLog.shared.write("could not write \(file.name) for \(policy.runtimeID): \(error)")
            return nil
        }
    }
}
