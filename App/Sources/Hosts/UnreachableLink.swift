import AgentsKit
import Foundation

/// A link to nowhere: every call fails at once with `offline` (037). Handed out for a
/// server the window has no connection to, so a call meant for it can never reach the
/// Mac's daemon by falling through.
struct UnreachableLink: DaemonLink {
    func transport() async throws -> any LineTransport { throw HostProblem.offline }
    func start() async throws { throw HostProblem.offline }
}
