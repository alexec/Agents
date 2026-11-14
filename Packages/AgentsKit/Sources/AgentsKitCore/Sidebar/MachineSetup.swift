import Foundation

/// New Machine in one step (#5204): the sheet asks for the folders to clone and the runtime to
/// sign in, with the machine itself. The control plane clones the folders once the machine
/// joins (`ProviderCreate.clones`, #1122). The sign-in needs the person's browser, so the
/// client that made the machine keeps it here and opens the runtime's sign-in by itself once
/// the machine has joined and its runtime is installed. The window, the Remote and the web
/// page (`Web/src/model/machineSetup.ts`) do the same.
public struct MachineSetups: Equatable, Sendable {
    /// The runtime to sign in, by the name of the machine New Machine made, until it is
    /// signed in, needs no sign-in, or the wait is over.
    public private(set) var signIns: [String: Pending] = [:]

    public struct Pending: Equatable, Sendable {
        public var runtimeID: String
        public var since: Date
    }

    /// The runtimes New Machine offers to sign in: the ones a server signs in from a client
    /// (#3349), Claude first.
    public static let signInRuntimes: [Runtime] = [RuntimeCatalog.claude, RuntimeCatalog.codex]

    /// How long a machine is waited for: a provider's first boot and the runtimes' install take
    /// minutes. After that the machine's own line says it needs a sign-in, as before.
    public static let wait: TimeInterval = 30 * 60

    public init() {}

    /// New Machine made `name`; nil runtime is Don't sign in.
    public mutating func made(_ name: String, signIn runtimeID: String?, at now: Date = Date()) {
        signIns[name] = runtimeID.map { Pending(runtimeID: $0, since: now) }
    }

    /// The machine needs nothing more from this client.
    public mutating func done(_ name: String) {
        signIns[name] = nil
    }

    /// The machines that wait to be signed in and have joined, by their names.
    public func joined(_ names: some Sequence<String>, at now: Date = Date()) -> [(name: String, runtimeID: String)] {
        names.compactMap { name in
            guard let pending = signIns[name], now.timeIntervalSince(pending.since) < Self.wait else { return nil }
            return (name, pending.runtimeID)
        }
    }

    /// Drops the waits that are over.
    public mutating func expire(at now: Date = Date()) {
        signIns = signIns.filter { now.timeIntervalSince($0.value.since) < Self.wait }
    }

    /// What to do for a machine that joined, from its runtimes as it lists them.
    public enum Step: Equatable, Sendable {
        /// Its runtime is not listed or still installing: read it again later.
        case wait
        /// Open the runtime's sign-in.
        case signIn(Runtime)
        /// Signed in already, or it cannot sign in from a client: nothing to open.
        case done
    }

    /// `canSignIn` is whether the machine signs in from a client (`runtimes.signIn.1`).
    public static func step(runtimeID: String, runtimes: [RuntimeStatus], canSignIn: Bool) -> Step {
        guard let status = runtimes.first(where: { $0.runtime.id == runtimeID }) else { return .wait }
        switch status.availability {
        case .installing, .missing: return .wait
        case .available, .needsSignIn:
            guard canSignIn, status.signIn != nil else { return .done }
            return status.needsSignIn ? .signIn(status.runtime) : .done
        case .failed, .installFailed: return .done
        }
    }
}
