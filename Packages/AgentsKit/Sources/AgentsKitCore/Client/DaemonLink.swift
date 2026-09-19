import Foundation

/// A way to reach the daemon, and a way to bring it up when it is not there.
///
/// Two things, because connecting and starting are two different failures: nothing is
/// listening yet, and nothing can be made to listen. The Mac's link opens a Unix
/// socket and spawns `agentsd`; a remote's link writes to a mailbox and has nothing to
/// start, because the Mac is either awake or it is not.
public protocol DaemonLink: Sendable {
    /// A fresh transport to the daemon. Throws when nothing answers.
    func transport() async throws -> any LineTransport

    /// Called once, after `transport()` failed, to bring the far end up. A link with
    /// nothing to start does nothing, and the caller then times out — which is the
    /// honest answer for a Mac that is asleep.
    func start() async throws
}

public extension DaemonLink {
    func start() async throws {}
}
