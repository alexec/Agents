import Foundation

/// The config files the app writes for a runtime that will read policy only off disk,
/// and the environment that points at them.
///
/// One runtime needs this and the rest do not. Grok's feature switches are read from a
/// file named by `GROK_CONFIG_PATH` and nowhere else — the same TOML handed over inline
/// was measured and ignored — so scoping it means writing a file (Research R6, R11).
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
        guard !policy.environmentFiles.isEmpty else { return base }
        var environment = base
        let directory = locations.root.appendingPathComponent("runtimes", isDirectory: true)
        for file in policy.environmentFiles {
            let url = directory.appendingPathComponent(file.name)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try file.contents.write(to: url, atomically: true, encoding: .utf8)
                environment[file.variable] = url.path
            } catch {
                DaemonLog.shared.write("could not write \(file.name) for \(policy.runtimeID): \(error)")
            }
        }
        return environment
    }
}
