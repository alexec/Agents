import Foundation

/// How Agents Host's window keeps its one connection to this Mac's host (#168).
///
/// The window counts the host's projects and working agents over a socket it keeps. It
/// used to treat any failed count as the host gone: it hung up and dialled again on the
/// next tick, every five seconds. A host that refused it (a stranger to its signature)
/// was dialled 25,000 times in two and a half days, each a code-signature check and a
/// log line. Now a refusal is not a loss: the connection is kept and the counts are not
/// asked for again on it. Only a connection that fails is dropped, and dialled again
/// after a wait that doubles from `first` to `longest`, with jitter so that nothing
/// that lost the host at the same moment comes back in step: `ReconnectSchedule`, which
/// every other client waits by too (#172).
public struct HostLinkPolicy: Sendable, Equatable {
    public static let first: TimeInterval = 5
    public static let longest: TimeInterval = 300
    public static let schedule = ReconnectSchedule(first: .seconds(first), longest: .seconds(longest))

    /// What a count that did not come back means.
    public enum Failure: Equatable, Sendable {
        /// The host answered no: keep the connection, stop asking on it.
        case refused
        /// No answer, or the connection broke: drop it and dial again later.
        case gone
    }

    public static func failure(_ error: any Error) -> Failure {
        (error as? JSONRPCError)?.code == DaemonAPI.Failure.notPermitted ? .refused : .gone
    }

    /// Not before this may it dial; nil when it may now.
    public private(set) var notBefore: Date?
    private var failures = 0

    public init() {}

    public func mayDial(at now: Date) -> Bool {
        notBefore.map { now >= $0 } ?? true
    }

    /// A dial failed or a kept connection broke. `jitter`, from 0 to 1, picks the wait
    /// between half and all of the doubled one.
    public mutating func failed(at now: Date, jitter: Double = ReconnectSchedule.randomJitter()) {
        failures += 1
        let wait = ReconnectSchedule.jittered(Self.schedule.nominal(afterFailures: failures), jitter)
        notBefore = now.addingTimeInterval(TimeInterval(wait.components.seconds)
                                           + TimeInterval(wait.components.attoseconds) / 1e18)
    }

    /// Connected: a later loss starts from the first wait again.
    public mutating func connected() {
        failures = 0
        notBefore = nil
    }
}
