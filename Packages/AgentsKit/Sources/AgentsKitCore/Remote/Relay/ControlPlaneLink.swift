// Not on Linux: the server build of agentsd has no relay (037, 046).
#if canImport(CryptoKit)
import Foundation

/// A connection to the control plane as this device: its address first, then the relay
/// when the address cannot be reached (T077). Nothing to start when neither answers, only
/// the reconnect loop to try again.
///
/// Each connection it makes records which way it went in `route`, so the Remote knows it
/// is away (#883): the Away line, and the terminal, live page and files that wait for the
/// address, read it.
public struct ControlPlaneLink: DaemonLink {
    public let dial: @Sendable () async throws -> any LineTransport
    public var relayed: (@Sendable () async throws -> any LineTransport)?
    /// This link's watcher for the address while relayed: one per pairing, so stopping an
    /// old pairing's does not stop the new one's (#208).
    public let watching: Watching
    /// Which way the last connection went.
    public let route: Route

    public init(dial: @escaping @Sendable () async throws -> any LineTransport,
                relayed: (@Sendable () async throws -> any LineTransport)?, watching: Watching = Watching()) {
        self.dial = dial
        self.relayed = relayed
        self.watching = watching
        route = Route()
    }

    /// The same link without the relay: for a second connection, which the relay cannot
    /// carry beside the first. Its route is its own, so it does not say the first's.
    public var addressOnly: ControlPlaneLink { ControlPlaneLink(dial: dial, relayed: nil, watching: watching) }

    /// How often a relayed connection looks for the address again.
    public static let lookAgain: Duration = .seconds(30)

    /// How long a dial gives the address, in seconds, for the dial to read: the whole of
    /// `addressPatience`, or `addressPatienceAfterFailing` once the address has failed and
    /// until it answers again (#884). Each failed connection away from home waited the
    /// whole ten seconds before trying the relay; an address that answers at all answers
    /// in much less, and the watcher still finds it every `lookAgain` with the whole wait.
    @TaskLocal public static var patience: TimeInterval = addressPatience
    public static let addressPatience: TimeInterval = 10
    public static let addressPatienceAfterFailing: TimeInterval = 3

    public func transport() async throws -> any LineTransport {
        do {
            let patience = relayed != nil && route.addressFailed ? Self.addressPatienceAfterFailing : Self.addressPatience
            let direct = try await Self.$patience.withValue(patience) { try await dial() }
            // The address answers this connection itself: nothing left to watch for (#208).
            if relayed != nil { watching.stop(keepsWatching: true) }
            route.set(.direct)
            return direct
        } catch let refusal as ControlAuth.Refusal {
            // `DaemonClient` keeps only "could not connect"; the model asks what was said.
            // A control plane that answered and refused is not one to go round.
            ControlPlaneLink.refused.set(refusal.reason)
            throw refusal
        } catch let refusal as ControlRefusal {
            // The address itself refused (suspended, over a plan's limit, #2235): the
            // relay dials the same address in the end, so going round would not help.
            ControlPlaneLink.hostedRefusal.set(refusal.line)
            throw refusal
        } catch {
            route.addressDidFail()
            guard let relayed else { throw error }
            let transport: any LineTransport
            do {
                transport = try await relayed()
            } catch let refusal as ControlAuth.Refusal {
                ControlPlaneLink.refused.set(refusal.reason)
                throw refusal
            } catch let refusal as ControlRefusal {
                ControlPlaneLink.hostedRefusal.set(refusal.line)
                throw refusal
            } catch RelayTrouble.notPaired {
                throw error
            }
            route.set(.relayed)
            watchForTheAddress(while: transport)
            return transport
        }
    }

    /// While relayed, try the address now and then; when it answers, end the relayed
    /// connection so the model reconnects, and the address wins. One watcher, for the
    /// latest relayed connection; it ends when the address answers, when this link next
    /// connects to the address by itself, or when its pairing is stopped (#208). It used
    /// to dial every half minute for good.
    private func watchForTheAddress(while relayed: any LineTransport) {
        let dial = self.dial
        let watching = self.watching
        watching.hold(relayed) {
            Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.lookAgain)
                    guard !Task.isCancelled else { return }
                    if let direct = try? await dial() {
                        direct.close()
                        watching.take()?.close()
                        return
                    }
                }
            }
        }
    }

    /// Which way the last connection went: `.none` before the first. And whether the
    /// address failed since it last answered.
    public final class Route: @unchecked Sendable {
        private let lock = NSLock()
        private var value = RemoteLink.none
        private var failed = false
        public init() {}
        public var current: RemoteLink { lock.withLock { value } }
        public var addressFailed: Bool { lock.withLock { failed } }
        func set(_ link: RemoteLink) {
            lock.withLock {
                value = link
                if link == .direct { failed = false }
            }
        }
        func addressDidFail() { lock.withLock { failed = true } }
    }

    /// The relayed connection in use, and the watcher looking for the address on its behalf.
    public final class Watching: @unchecked Sendable {
        private let lock = NSLock()
        private var relayed: (any LineTransport)?
        private var watcher: Task<Void, Never>?
        private var stopped = false

        public init() {}

        /// Holds the connection, and starts a watcher with `watch` when none is running.
        /// Nothing once stopped.
        func hold(_ transport: any LineTransport, watch: () -> Task<Void, Never>) {
            lock.withLock {
                guard !stopped else { return }
                relayed = transport
                if watcher == nil { watcher = watch() }
            }
        }

        /// The relayed connection, to close: the address answered. The watcher is done.
        func take() -> (any LineTransport)? {
            lock.withLock {
                defer { relayed = nil; watcher = nil }
                return relayed
            }
        }

        /// No more watching. `keepsWatching` lets a later relayed connection watch again;
        /// without it, as for a pairing replaced, nothing does.
        public func stop(keepsWatching: Bool = false) {
            let ended = lock.withLock {
                defer { relayed = nil; watcher = nil; if !keepsWatching { stopped = true } }
                return watcher
            }
            ended?.cancel()
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
#endif
