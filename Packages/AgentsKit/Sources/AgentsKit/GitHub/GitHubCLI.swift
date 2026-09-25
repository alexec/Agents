import Foundation

/// The person's own `gh`, run by the daemon (038 R1).
///
/// Their sign-in is `gh`'s: a token for each host in the keychain, which the daemon never
/// holds. The app stores no token and asks for none (FR-002). `--hostname` is how an
/// Enterprise host is reached.
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

    /// Why a call gave nothing usable, as the section says it.
    public struct Failure: Error, Sendable {
        public var problem: PullRequestProblem
        /// The body, when GitHub answered with one: GraphQL gives partial data with
        /// its errors, and the viewer's login is worth having from it.
        public var body: Data?
    }

    /// A GraphQL query. Variables are strings, passed with `-f`.
    public func graphql(_ query: String, variables: [String: String], host: String) async throws -> Data {
        var arguments = ["api", "graphql", "--hostname", host, "-f", "query=\(query)"]
        for (key, value) in variables.sorted(by: { $0.key < $1.key }) {
            arguments += ["-f", "\(key)=\(value)"]
        }
        return try await run(arguments, host: host)
    }

    /// A REST call, for replying (R7). Fields are strings, passed with `-f`, and numbers
    /// with `-F`.
    public func api(method: String, path: String, fields: [String: String] = [:],
                    numbers: [String: Int] = [:], host: String) async throws -> Data {
        var arguments = ["api", "--hostname", host, "-X", method, path]
        for (key, value) in fields.sorted(by: { $0.key < $1.key }) { arguments += ["-f", "\(key)=\(value)"] }
        for (key, value) in numbers.sorted(by: { $0.key < $1.key }) { arguments += ["-F", "\(key)=\(value)"] }
        return try await run(arguments, host: host)
    }

    private func run(_ arguments: [String], host: String) async throws -> Data {
        guard let gh = executable() else { throw Failure(problem: .noCLI) }
        let outcome = try await Self.process(gh, arguments)
        let body = Data(outcome.output.utf8)
        if outcome.succeeded { return body }
        throw Failure(problem: await classify(outcome, body: body, host: host, gh: gh), body: body)
    }

    /// Which of FR-003's lines this failure is. GitHub's own words first: a typed
    /// GraphQL error says exactly what happened. Then whether `gh` is signed in to that
    /// host at all. Anything else is the network or a rate limit, which keeps the last
    /// good rows rather than replacing them (FR-009).
    private func classify(_ outcome: GitProcess.Outcome, body: Data, host: String, gh: URL) async -> PullRequestProblem {
        if let types = Self.errorTypes(in: body), types.contains(where: { $0 == "NOT_FOUND" || $0 == "FORBIDDEN" }) {
            return .cannotSee(host: host, repository: "", login: Self.viewer(in: body))
        }
        if let status = try? await Self.process(gh, ["auth", "status", "--hostname", host]), !status.succeeded {
            return .notSignedIn(host: host)
        }
        let said = outcome.errors.split(separator: "\n").first.map(String.init) ?? "gh failed"
        return .unreachable(said)
    }

    private static func process(_ gh: URL, _ arguments: [String]) async throws -> GitProcess.Outcome {
        try await GitProcess(executable: gh, arguments: arguments,
                             environment: ["GH_PROMPT_DISABLED": "1", "GH_NO_UPDATE_NOTIFIER": "1",
                                           "NO_COLOR": "1"]).run()
    }

    static func errorTypes(in body: Data) -> [String]? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let errors = object["errors"] as? [[String: Any]] else { return nil }
        return errors.compactMap { $0["type"] as? String }
    }

    static func viewer(in body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let data = object["data"] as? [String: Any],
              let viewer = data["viewer"] as? [String: Any] else { return nil }
        return viewer["login"] as? String
    }
}
