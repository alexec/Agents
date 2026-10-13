import AgentsKitCore
import Foundation

/// The app's MCP client, for the control plane's workspace providers (#691, research R1): a
/// connection, its tools, and calls to them, over stdio or streamable http. Nothing of
/// `MCPClient`'s events, resources or pool.
///
/// Logged through `log`: the server's name and what happened in a word, never its command,
/// environment, headers or what it answered.
public actor MCPToolClient {
    /// Why a call didn't get an answer, in words a person can read.
    public struct Failure: Error, Equatable, Sendable, CustomStringConvertible {
        public var description: String
        /// The server needs a sign-in first (401).
        public var authRequired: Bool
        public var timedOut: Bool
        /// The connection went (the server ended, the session was forgotten, nothing
        /// answered), so a new one may do what this one couldn't. Never after the server
        /// heard the call and said no, or ran out of time.
        public var retriable = false
    }

    private let client: MCPClient

    public init(server: MCPServer, cwd: URL, timeout: Duration = .seconds(30),
                log: @escaping @Sendable (String) -> Void) {
        client = MCPClient(server: server, cwd: cwd, timeout: timeout, log: log)
    }

    /// Starts the server or opens the session, and `initialize`.
    public func connect() async throws(Failure) {
        do { try await client.connect() } catch { throw Self.failure(error) }
    }

    /// Every tool's name.
    public func listTools() async throws(Failure) -> [String] {
        do { return try await client.listTools().map(\.name) } catch { throw Self.failure(error) }
    }

    /// Every tool, as the server described it: name, description, input schema and
    /// annotations (#858).
    public func describeTools() async throws(Failure) -> [JSONValue] {
        do { return try await client.listTools().map(\.raw) } catch { throw Self.failure(error) }
    }

    /// `tools/call`'s whole result.
    public func callTool(_ name: String, arguments: JSONValue = [:], timeout: Duration? = nil) async throws(Failure) -> JSONValue {
        do { return try await client.callTool(name, arguments: arguments, timeout: timeout) } catch { throw Self.failure(error) }
    }

    public func end() async {
        await client.end()
    }

    static func failure(_ error: any Error) -> Failure {
        guard let failure = error as? MCPClient.Failure else {
            return Failure(description: "\(error)", authRequired: false, timedOut: false)
        }
        let words: String = switch failure {
        case .authRequired: "It wants a sign-in first."
        case .httpStatus(let status): "It answered with HTTP \(status)."
        case .sessionExpired: "It forgot this session."
        case .unreachable(let why): why
        case .stopped(let why): why.isEmpty ? "The server stopped." : why
        case .timedOut: "It didn’t answer in time."
        case .refused(_, let message, _): message
        case .notMCP: "What it answered isn’t MCP."
        case .transportNotSupported: "It only speaks the old SSE transport."
        }
        let retriable = switch failure {
        case .stopped, .sessionExpired, .unreachable: true
        default: false
        }
        return Failure(description: words, authRequired: failure.isAuthRequired, timedOut: failure == .timedOut,
                       retriable: retriable)
    }
}

private extension MCPClient.Failure {
    var isAuthRequired: Bool { if case .authRequired = self { true } else { false } }
}
