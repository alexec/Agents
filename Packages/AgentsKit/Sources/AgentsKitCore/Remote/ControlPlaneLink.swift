import Foundation

/// A connection to the control plane as this device, at its address (T077). Nothing to
/// start when it does not answer, only the reconnect loop to try again.
public struct ControlPlaneLink: DaemonLink {
    public let dial: @Sendable () async throws -> any LineTransport

    public init(dial: @escaping @Sendable () async throws -> any LineTransport) {
        self.dial = dial
    }

    /// How long a dial gives the address, in seconds, for the dial to read.
    public static let patience: TimeInterval = 10

    public func transport() async throws -> any LineTransport {
        do {
            return try await dial()
        } catch let refusal as ControlAuth.Refusal {
            // `DaemonClient` keeps only "could not connect"; the model asks what was said.
            ControlPlaneLink.refused.set(refusal.reason)
            throw refusal
        } catch let refusal as ControlRefusal {
            // The address itself refused (suspended, over a plan's limit, #2235).
            ControlPlaneLink.hostedRefusal.set(refusal.line)
            throw refusal
        }
    }

    public func start() async throws {}

    /// The last refusal the control plane gave this device, taken once.
    public static let refused = Refused()

    public final class Refused: @unchecked Sendable {
        private let lock = NSLock()
        private var reason: ControlAuth.Reason?
        func set(_ reason: ControlAuth.Reason) { lock.withLock { self.reason = reason } }
        public func take() -> ControlAuth.Reason? { lock.withLock { defer { reason = nil }; return reason } }
    }

    /// The last line the address itself answered with, refusing the connection outright
    /// (suspended, over a plan's limit, #2235), taken once.
    public static let hostedRefusal = HostedRefusal()

    public final class HostedRefusal: @unchecked Sendable {
        private let lock = NSLock()
        private var line: String?
        func set(_ line: String) { lock.withLock { self.line = line } }
        public func take() -> String? { lock.withLock { defer { line = nil }; return line } }
    }
}
