import Foundation

/// The person's own `gh`, run by the daemon, which the skills catalogue reads GitHub
/// through when it is signed in, for the higher hourly limit.
///
/// Their sign-in is `gh`'s: a token for each host in the keychain, which the daemon never
/// holds. The app stores no token and asks for none.
public struct GitHubCLI: Sendable {
    /// Where `gh` is, or nil when it isn't installed. A test puts a fake one here.
    let executable: @Sendable () -> URL?

    public init(executable: @escaping @Sendable () -> URL? = GitHubCLI.onPath) {
        self.executable = executable
    }

    /// `gh` on the person's PATH.
    public static let onPath: @Sendable () -> URL? = {
        for directory in LoginShellPath.directories() {
            let candidate = URL(filePath: directory).appending(path: "gh")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// Why a call gave nothing usable: `gh` is missing, or said this.
    public struct Failure: Error, Sendable {
        public var said: String
    }

    /// A REST call.
    public func api(method: String, path: String, host: String) async throws -> Data {
        guard let gh = executable() else { throw Failure(said: "gh is not installed") }
        let call = GitProcess(
            executable: gh, arguments: ["api", "--hostname", host, "-X", method, path],
            environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1", "NO_COLOR": "1"])
        // As long as the URLSession path beside it waits, give or take (#207).
        call.deadline = .seconds(20)
        let outcome = try await call.run()
        if outcome.truncated { throw Failure(said: "gh answered with more than \(call.outputLimit) bytes") }
        if outcome.succeeded { return outcome.data }
        throw Failure(said: outcome.errors.split(separator: "\n").first.map(String.init) ?? "gh failed")
    }
}
